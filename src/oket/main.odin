package main

import "core:fmt"
import "core:os"
import "vendor:glfw"
import "../gfx"
import "../pty"

WIDTH :: 1200
HEIGHT :: 760
TITLE :: "Oket"
APP_ID :: "oket" // Wayland app-id / X11 instance name

// The one flag, and it is an escape hatch rather than a setting (§13, §14): a plugin bad enough
// to get past the fault net is one you have to be able to start without.
NO_PLUGINS :: "--no-plugins"

flag :: proc(name: string) -> bool {
    for arg in os.args[1:] {
        if arg == name {
            return true
        }
    }
    return false
}

// A Wayland swap blocks on a frame callback that stops arriving once the window is off-screen,
// and that wait never dispatches xdg_wm_base.ping, so the compositor declares the window dead.
// Pace on the event wait there — tear-free, the compositor presents on its own vblank.
swap_interval :: proc(platform: i32) -> i32 {
    return platform == glfw.PLATFORM_WAYLAND ? 0 : 1
}

main :: proc() {
    if !glfw.Init() {
        desc, code := glfw.GetError()
        fmt.eprintfln("glfw.Init failed (%d): %s", code, desc)
        os.exit(1)
    }
    defer glfw.Terminate()

    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, gfx.GL_MAJOR)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, gfx.GL_MINOR)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
    glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true) // required on macOS

    // The window's identity to the desktop; an empty app-id is invisible to a WM rule.
    glfw.WindowHintString(glfw.WAYLAND_APP_ID, APP_ID)
    glfw.WindowHintString(glfw.X11_CLASS_NAME, TITLE)
    glfw.WindowHintString(glfw.X11_INSTANCE_NAME, APP_ID)

    a: App
    a.window = glfw.CreateWindow(WIDTH, HEIGHT, TITLE, nil, nil)
    if a.window == nil {
        desc, code := glfw.GetError()
        fmt.eprintfln("glfw.CreateWindow failed (%d): %s", code, desc)
        os.exit(1)
    }
    defer glfw.DestroyWindow(a.window)

    glfw.MakeContextCurrent(a.window)
    glfw.SwapInterval(swap_interval(glfw.GetPlatform()))
    gfx.gl_init(glfw.gl_set_proc_address)

    sx, _ := glfw.GetWindowContentScale(a.window)

    // An empty stack is not an error: the kernel draws with the bitmap and says so on screen.
    faces, _ := font_stack_load(sx)
    atlas, atlas_ok := gfx.atlas_make(faces)
    if !atlas_ok {
        fmt.eprintln("the built-in fallback atlas failed to parse; this build is broken")
        os.exit(1)
    }
    if !gfx.painter_init(&a.painter, atlas) {
        os.exit(1)
    }
    // A baked face is already rasterized at the display's scale; only the bitmap scales up.
    gfx.painter_set_scale(&a.painter, len(faces) > 0 ? 1 : sx)

    // Input first: binds.conf may spell a chord as a layout glyph, and resolving one needs the
    // scancode base this sets.
    input_init(&a)
    app_init(&a)
    defer app_destroy(&a)

    // §10's net, before anything can dispatch, and the watchdog that turns a hang into the
    // same named death a fault gets. Without them nothing below should be loading a plugin
    // by itself.
    fault_install()
    fault_watchdog_start()
    if !flag(NO_PLUGINS) {
        plug_autoload(&a)
    }

    // A session's reader thread has to reach the frame loop, which is parked in WaitEvents.
    pty.wake = proc() {glfw.PostEmptyEvent()}

    // The ring opens on a listing of the working directory. The descriptor is what makes it
    // renderable without a kind of its own in here.
    ring_add(&a, listing_open(&a, "."))

    for !glfw.WindowShouldClose(a.window) && !a.quit {
        w, h := glfw.GetFramebufferSize(a.window)
        cols, rows := gfx.painter_fit(&a.painter, w, h)
        gfx.grid_resize(&a.grid, cols, rows)

        // Writes land at one point in the frame (§6): every session's output into its
        // document first, then the exit code that advances a chain waiting on one.
        term_pump(&a)
        sh_pump(&a)
        chain_pump(&a)
        docs_settle(&a)
        // Whose generation moved, told once the drain has settled. A plugin that answered
        // "not finished" is the one thing no keystroke and no reader thread will wake, so the
        // frame after it is polled rather than waited for (§9).
        latched := plug_pump(&a)

        surface_draw(&a)

        gfx.gl_clear(w, h, a.theme[.Bg])
        gfx.painter_draw(&a.painter, &a.grid, w, h)
        glfw.SwapBuffers(a.window)
        free_all(context.temp_allocator) // the frame's cell tables and bar text

        if latched {
            glfw.PollEvents() // a parse is mid-slice; the next frame is its next slice
        } else {
            glfw.WaitEvents() // idle until a key, a click, a resize, or a session's reader
        }
    }
}

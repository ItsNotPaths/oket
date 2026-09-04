package main

import "core:fmt"
import "core:os"
import "core:time"
import "vendor:glfw"
import "../gfx"
import "../wake"

WIDTH :: 1200
HEIGHT :: 760
TITLE :: "Oket"
APP_ID :: "oket" // Wayland app-id / X11 instance name

// Both flags are escape hatches rather than settings (§13, §14). `--no-plugins` is for a plugin
// bad enough to get past the fault net; `--safe` is that plus the session, for the start where
// what breaks you is the file the last one reopened.
NO_PLUGINS :: "--no-plugins"
SAFE :: "--safe"

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

    // A session's reader thread, and the I/O worker, both have to reach the frame loop, which
    // is parked in WaitEvents. Before autoload: a plugin may start a job in its entry point,
    // and a completion nobody wakes for is a frame that never comes.
    wake.hook = proc() {glfw.PostEmptyEvent()}

    // §10's net, before anything can dispatch, and the watchdog that turns a hang into the
    // same named death a fault gets. Without them nothing below should be loading a plugin
    // by itself.
    fault_install()
    fault_watchdog_start()
    // Before autoload, and it reads the file before it opens it for the handler: a plugin an
    // earlier start died IN is held back, and the handler gets somewhere to name the next one
    // (§13).
    quarantine_open(&a)
    if a.start == .Ordinary {
        plug_autoload(&a)
    }

    // The ring: what the last session had, and the home page when it had nothing. The page is
    // the DEFAULT DOCUMENT and not a listing (§13) — the working directory is a row on it, and
    // a listing cannot say that a plugin is quarantined or that this start is a safe one.
    // A session that DID restore gets the news in the bar instead, because a page that stole
    // the focus from the files you left open would be the worse answer.
    if a.start == .Safe || !session_restore(&a) {
        ring_add(&a, home_open(&a))
    } else if home_news(&a) {
        message_set(&a, "this start has something to report; :home says what")
    }

    // The strip's motion is stepped on the CLOCK and not on the frame (PANELS.md §7), so this
    // is what a faked one stands in for: the loop measures, `panels_step` decays.
    last := time.tick_now()
    for !glfw.WindowShouldClose(a.window) && !a.quit {
        w, h := glfw.GetFramebufferSize(a.window)
        cols, rows := gfx.painter_fit(&a.painter, w, h)
        cw, ch := gfx.painter_cell(&a.painter)
        surface_fit(&a, cols, rows, {cw, ch})
        now := time.tick_now()
        moving := panels_step(&a, f32(time.duration_seconds(time.tick_diff(last, now))))
        last = now

        // Writes land at one point in the frame (§6): every session's output into its
        // document first, then the exit code that advances a chain waiting on one.
        term_pump(&a)
        sh_pump(&a)
        chain_pump(&a)
        settled := docs_settle(&a) // and, with it, the view pipeline (VIEWS.md §5)
        io_pump(&a) // before the moved pass, so what an I/O handler wrote is reported once
        // Whose generation moved, told once the drain has settled. A plugin that answered
        // "not finished" is the one thing no keystroke and no reader thread will wake, so the
        // frame after it is polled rather than waited for (§9). A view stage says the same
        // thing the same way.
        latched := plug_pump(&a) | settled

        surface_draw(&a)

        gfx.gl_clear(w, h, chrome_bg(&a))
        surface_paint(&a, w, h)
        glfw.SwapBuffers(a.window)
        free_all(context.temp_allocator) // the frame's cell tables and bar text

        if latched || moving {
            // A parse is mid-slice, or the strip is between two places. Neither is a keystroke
            // and neither will wake a wait, so the next frame is asked for rather than waited on.
            glfw.PollEvents()
        } else {
            glfw.WaitEvents() // idle until a key, a click, a resize, or a session's reader
            last = time.tick_now() // the wait was idle; a motion the event starts is not behind
        }
    }
    session_save(&a) // before app_destroy, which is where the ring it writes down goes
}

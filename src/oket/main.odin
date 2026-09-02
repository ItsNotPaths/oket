package main

import "core:fmt"
import "core:os"
import "vendor:glfw"
import "../gfx"
import "../store"
import "../view"

WIDTH :: 1200
HEIGHT :: 760
TITLE :: "Oket"
APP_ID :: "oket" // Wayland app-id / X11 instance name

// A Wayland swap blocks on a frame callback that stops arriving once the window is off-screen,
// and that wait never dispatches xdg_wm_base.ping, so the compositor declares the window dead.
// Pace on the event wait there — tear-free, the compositor presents on its own vblank.
swap_interval :: proc(platform: i32) -> i32 {
    return platform == glfw.PLATFORM_WAYLAND ? 0 : 1
}

// One chord until the bind table lands (§8, stage 4); it replaces this wholesale.
key_callback :: proc "c" (w: glfw.WindowHandle, key, scancode, action, mods: i32) {
    if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
        glfw.SetWindowShouldClose(w, true)
    }
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

    window := glfw.CreateWindow(WIDTH, HEIGHT, TITLE, nil, nil)
    if window == nil {
        desc, code := glfw.GetError()
        fmt.eprintfln("glfw.CreateWindow failed (%d): %s", code, desc)
        os.exit(1)
    }
    defer glfw.DestroyWindow(window)

    glfw.MakeContextCurrent(window)
    glfw.SwapInterval(swap_interval(glfw.GetPlatform()))
    glfw.SetKeyCallback(window, key_callback)
    gfx.gl_init(glfw.gl_set_proc_address)

    sx, _ := glfw.GetWindowContentScale(window)

    // An empty stack is not an error: the kernel draws with the bitmap and says so on screen.
    faces, _ := font_stack_load(sx)
    atlas, atlas_ok := gfx.atlas_make(faces)
    if !atlas_ok {
        fmt.eprintln("the built-in fallback atlas failed to parse; this build is broken")
        os.exit(1)
    }

    painter: gfx.Painter
    if !gfx.painter_init(&painter, atlas) {
        os.exit(1)
    }
    defer gfx.painter_destroy(&painter) // the atlas and its faces go with it

    // A baked face is already rasterized at the display's scale; only the bitmap scales up.
    gfx.painter_set_scale(&painter, len(faces) > 0 ? 1 : sx)

    theme := gfx.DEFAULT_THEME
    grid: gfx.Grid
    defer gfx.grid_destroy(&grid)

    // One hardcoded surface until stage 5's ring; the descriptor is what makes it renderable
    // without a kind of its own in here.
    docs: store.Store
    defer store.store_destroy(&docs)
    id := listing_open(&docs, ".")
    v: view.View

    for !glfw.WindowShouldClose(window) {
        w, h := glfw.GetFramebufferSize(window)
        cols, rows := gfx.painter_fit(&painter, w, h)
        gfx.grid_resize(&grid, cols, rows)

        surface_draw(&grid, theme, &painter.atlas, &docs, id, v)

        gfx.gl_clear(w, h, theme[.Bg])
        gfx.painter_draw(&painter, &grid, w, h)
        glfw.SwapBuffers(window)
        free_all(context.temp_allocator) // the frame's cell tables and bar text

        // Idle until an event; stage 6's terminal is the first thing to need a deadline here.
        glfw.WaitEvents()
    }
}

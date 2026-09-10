package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
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

// Every argument that is not a flag: what this start was told to open. A leading `-` is the
// only test, which is why a file called `-x` is opened as `./-x` — the rule every other program
// on the machine uses.
args_paths :: proc(args: []string, allocator := context.allocator) -> []string {
    out := make([dynamic]string, allocator)
    for arg in args {
        if !strings.has_prefix(arg, "-") && arg != "" {
            append(&out, arg)
        }
    }
    return out[:]
}

// The first directory named on the command line, else the working directory this start was
// launched from. Not the LIVE working directory: that is a thing a shell step can move, and a
// terminal opened after one had moved it would start somewhere the last one did not.
start_dir :: proc(args: []string, allocator := context.allocator) -> string {
    for path in args_paths(args, context.temp_allocator) {
        if os.is_dir(path) {
            return strings.clone(path_abs(path), allocator)
        }
    }
    return os.get_working_directory(allocator) or_else ""
}

// Each one, as though it had been typed — the same shape a session has (session.odin), so an
// argument and a restored line reach `:open` through one path. Answers whether anything landed.
args_open :: proc(a: ^App, args: []string) -> (opened: bool) {
    for path in args_paths(args, context.temp_allocator) {
        cl_exec(a, fmt.tprintf(":open %s", sh_quote(path, context.temp_allocator)))
        opened |= ring_focused(a) != nil
    }
    return
}

// A Wayland swap blocks on a frame callback that stops arriving once the window is off-screen,
// and that wait would starve the event pump. Pace on the event wait there — tear-free, the
// compositor presents on its own vblank.
swap_interval :: proc(driver: string) -> i32 {
    return driver == "wayland" ? 0 : 1
}

// gfx's loader shape over SDL's lookup, so nothing above gfx needs the GL package.
gl_loader :: proc(p: rawptr, name: cstring) {
    (^sdl.FunctionPointer)(p)^ = sdl.GL_GetProcAddress(name)
}

main :: proc() {
    // Before the window, because install.sh runs these on a machine with no display. The App is
    // bare on purpose: these three read directories and write files, and none of them wants a
    // renderer, a plugin or a bind table (install.odin).
    {
        a: App
        a.home = home_resolve()
        defer home_destroy(&a.home)
        if install_cli(&a, os.args[1:]) {
            return
        }
    }
    // §6's second oket, before SDL: it brings up only what it needs, opens no window, installs
    // no fault net, and runs a file instead of a frame loop (harness.odin).
    if flag(HARNESS) {
        os.exit(harness_main(os.args[1:]))
    }
    // The window's identity to the desktop; an empty app-id is invisible to a WM rule.
    sdl.SetHint(sdl.HINT_APP_ID, APP_ID)
    if !sdl.Init({.VIDEO}) {
        fmt.eprintfln("SDL_Init failed: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.Quit()

    sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, gfx.GL_MAJOR)
    sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, gfx.GL_MINOR)
    sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))
    // Forward-compatible is required on macOS for a core profile.
    sdl.GL_SetAttribute(.CONTEXT_FLAGS, i32(transmute(u32)sdl.GL_CONTEXT_FORWARD_COMPATIBLE_FLAG))

    a: App
    a.window = sdl.CreateWindow(TITLE, WIDTH, HEIGHT, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY})
    if a.window == nil {
        fmt.eprintfln("SDL_CreateWindow failed: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.DestroyWindow(a.window)

    glctx := sdl.GL_CreateContext(a.window) // and it is current on this thread from here on
    if glctx == nil {
        fmt.eprintfln("SDL_GL_CreateContext failed: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.GL_DestroyContext(glctx)
    sdl.GL_SetSwapInterval(swap_interval(string(sdl.GetCurrentVideoDriver())))
    gfx.gl_init(gl_loader)

    sx := sdl.GetWindowDisplayScale(a.window)
    if sx <= 0 {
        sx = 1 // a failed scale query answers 0, which would size every face at 0px
    }

    // An empty stack is not an error: the kernel draws with the bitmap and says so on screen.
    faces, used := font_stack_load(sx)
    font_init(&a, used)
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
    // The environment the plugins and every shell step read their directories out of
    // (path.odin). Said here rather than in app_init because it is PROCESS state: a test holds
    // an App of its own and must not reach into this one's environment. Before app_init,
    // because that is where a plugin loads and asks.
    home_export()
    app_init(&a, home_resolve())
    defer app_destroy(&a)

    // A configured size is the baseline `font.reset` returns to: it is what this user asked
    // for, where the display's number is only what nobody overrode. A 0, or one the atlas
    // refuses, leaves both alone.
    if font_apply(&a, a.config.font_px) {
        a.font_system = a.font_px
    }

    // A session's reader thread, and the I/O worker, both have to reach the frame loop, which
    // is parked in WaitEvents. Before autoload: a plugin may start a job in its entry point,
    // and a completion nobody wakes for is a frame that never comes.
    wake.hook = proc() {
        ev: sdl.Event
        ev.type = .USER
        _ = sdl.PushEvent(&ev) // thread-safe by contract, which is the whole point of the hook
    }

    // §10's net, before anything can dispatch, and the watchdog that turns a hang into the
    // same named death a fault gets. Without them nothing below should be loading a plugin
    // by itself.
    fault_install()
    fault_watchdog_start()
    // Before autoload, and it reads the file before it opens it for the handler: a plugin an
    // earlier start died IN is held back, and the handler gets somewhere to name the next one
    // (§13).
    quarantine_open(&a)
    // The other file the handler cannot open for itself (§5): a fault's frames land here.
    fault_trace_open(&a)
    if a.start == .Ordinary {
        plug_autoload(&a)
    }

    // The ring: what the last session had, and the home page when it had nothing. The page is
    // the DEFAULT DOCUMENT and not a listing (§13) — the working directory is a row on it, and
    // a listing cannot say that a plugin is quarantined or that this start is a safe one.
    // A session that DID restore gets the news in the bar instead, because a page that stole
    // the focus from the files you left open would be the worse answer.
    // An argument beats both. This start was TOLD where to go, and a page offering the working
    // directory is what a start told NOTHING is for.
    if !args_open(&a, os.args[1:]) && (a.start == .Safe || !session_restore(&a)) {
        ring_add(&a, home_open(&a))
    } else if home_news(&a) {
        message_set(&a, "this start has something to report; :home says what")
    }

    // The strip's motion is stepped on the CLOCK and not on the frame (PANELS.md §7), so this
    // is what a faked one stands in for: the loop measures, `panels_step` decays.
    last := time.tick_now()
    for !a.quit {
        w, h: i32
        sdl.GetWindowSizeInPixels(a.window, &w, &h)
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
        ime_area_update(&a) // after the draw laid out, so a moved caret re-docks the candidates

        gfx.gl_clear(w, h, ground_bg(&a))
        surface_paint(&a, w, h)
        sdl.GL_SwapWindow(a.window)
        free_all(context.temp_allocator) // the frame's cell tables and bar text

        if latched || moving {
            // A parse is mid-slice, or the strip is between two places. Neither is a keystroke
            // and neither will wake a wait, so the next frame is asked for rather than waited on.
            input_pump(&a, false)
        } else {
            input_pump(&a, true) // idle until a key, a click, a resize, or a session's reader
            last = time.tick_now() // the wait was idle; a motion the event starts is not behind
        }
    }
    session_save(&a) // before app_destroy, which is where the ring it writes down goes
}

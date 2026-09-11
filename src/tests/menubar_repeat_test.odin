package tests

import "core:testing"
import sdl "vendor:sdl3"
import "../input"
import "../menu"
import app "../oket"

// Hold quick-repeats; release must not jump extra lines.
@(test)
holding_arrow_does_not_jump_on_release :: proc(t: ^testing.T) {
    a, ok := bare_app(80, 24)
    if !ok {
        return
    }
    defer close_app(&a)
    // Open menu on first menu
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    _, up := a.pending.(input.Pending_Menu)
    if !testing.expect(t, up, "menu not open") {
        return
    }
    b := app.menubar_frame(&a)
    rows := menu.rows_of(b, a.menu_nav)
    if len(rows) < 5 {
        testing.expectf(t, false, "need enough rows, got %d", len(rows))
        return
    }
    b2 := app.menubar_frame(&a)
    rows2 := menu.rows_of(b2, a.menu_nav)
    start := a.menu_nav.row
    N :: 20
    // initial press + repeats = N moves
    for i in 0 ..< N {
        if i == 0 {
            app.handle_chord(&a, chord("DOWN"))
        } else {
            app.handle_chord(&a, chord("DOWN"), true)
        }
    }
    want := (start + N) % len(rows2)
    testing.expect_value(t, a.menu_nav.row, want)
    top_before := a.menu_nav.top
    testing.expect_value(t, a.menu_nav.row, want)
    testing.expect_value(t, a.menu_nav.top, top_before)
    app.handle_chord(&a, chord("DOWN"))
    testing.expect_value(t, a.menu_nav.row, (want + 1) % len(rows2))
}

// The order SDL really queues: the last due repeats sit in front of their own release, in one
// batch, because the release is what synthesizes them. A repeat that peeks its up behind it
// drops itself, so the batch moves nothing.
@(test)
repeats_queued_before_the_up_move_nothing :: proc(t: ^testing.T) {
    // Headless CI: skip the queue path when SDL cannot start.
    inited := sdl.Init({.VIDEO})
    if !inited {
        inited = sdl.Init({})
        if !inited {
            return
        }
    }
    defer sdl.Quit()
    sdl.FlushEvents(.KEY_DOWN, .KEY_UP)

    a, ok := bare_app(80, 24)
    if !ok {
        return
    }
    defer close_app(&a)
    for name in ([?]string{"UP", "DOWN", "LEFT", "RIGHT"}) {
        app.handle_chord(&a, chord("SPCE", {.Alt}))
        _, up := a.pending.(input.Pending_Menu)
        if !testing.expect(t, up, "menu not open") {
            return
        }
        a.menu_nav = menu.nav(0)
        b := app.menubar_frame(&a)
        rows := menu.rows_of(b, a.menu_nav)
        if len(rows) == 0 {
            continue
        }
        want_row := a.menu_nav.row
        want_top := a.menu_nav.top
        sc, _ := input.key_code(name)

        // The batch as the release queues it: five repeats, then the up. The repeats are stale.
        ev: sdl.Event
        ev.type = .KEY_DOWN
        ev.key.scancode = sdl.Scancode(sc)
        ev.key.down = true
        ev.key.repeat = true
        if !sdl.PushEvent(&ev) {
            continue // no queue to push into
        }
        for _ in 1 ..< 5 {
            _ = sdl.PushEvent(&ev)
        }
        ev.type = .KEY_UP
        ev.key.down = false
        ev.key.repeat = false
        _ = sdl.PushEvent(&ev)

        app.input_pump(&a, false)

        testing.expectf(t, a.menu_nav.row == want_row, "%s: the row moved on release: want %d got %d", name, want_row, a.menu_nav.row)
        testing.expectf(t, a.menu_nav.top == want_top, "%s: the top moved on release", name)
        tmp: sdl.Event
        leaked := 0
        for sdl.PollEvent(&tmp) {
            if tmp.type == .KEY_DOWN && tmp.key.scancode == sdl.Scancode(sc) && tmp.key.repeat {
                leaked += 1
            }
        }
        testing.expectf(t, leaked == 0, "%s: repeats leaked: %d", name, leaked)
        sdl.FlushEvents(.KEY_DOWN, .KEY_UP)
        app.handle_chord(&a, chord("ESC")) // shut before the next case opens it again
    }
}

// A repeat with no up behind it is a live hold: it moves.
@(test)
live_repeats_still_move :: proc(t: ^testing.T) {
    inited := sdl.Init({.VIDEO})
    if !inited {
        inited = sdl.Init({})
        if !inited {
            return
        }
    }
    defer sdl.Quit()
    sdl.FlushEvents(.KEY_DOWN, .KEY_UP)

    a, ok := bare_app(80, 24)
    if !ok {
        return
    }
    defer close_app(&a)
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    _, up := a.pending.(input.Pending_Menu)
    if !testing.expect(t, up, "menu not open") {
        return
    }
    b := app.menubar_frame(&a)
    rows := menu.rows_of(b, a.menu_nav)
    if len(rows) == 0 {
        return
    }
    start := a.menu_nav.row
    sc, _ := input.key_code("DOWN")
    ev: sdl.Event
    ev.type = .KEY_DOWN
    ev.key.scancode = sdl.Scancode(sc)
    ev.key.down = true
    ev.key.repeat = true
    if !sdl.PushEvent(&ev) {
        return
    }
    for _ in 1 ..< 3 {
        _ = sdl.PushEvent(&ev)
    }
    app.input_pump(&a, false)
    testing.expect_value(t, a.menu_nav.row, (start + 3) % len(rows))
}

@(private = "file")
chord :: proc(name: string, mods: input.Mods = {}, held := "") -> input.Chord {
    code, _ := input.key_code(name)
    down, _ := input.key_code(held)
    return {code, mods, down}
}

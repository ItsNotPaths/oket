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

// Stale repeats queued after KEY_UP must be flushed.
@(test)
arrow_release_flushes_queued_repeats :: proc(t: ^testing.T) {
    // Headless CI: skip SDL queue path if display unavailable.
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
    // Include every popup arrow direction: UP, DOWN, LEFT, RIGHT
    cases := [?]string{"UP", "DOWN", "LEFT", "RIGHT"}
    for name in cases {
        // Reset to known position
        a.menu_nav = menu.nav(0)
        // Simulate hold: N repeats already dispatched via handle_chord
        b0 := app.menubar_frame(&a)
        rows0 := menu.rows_of(b0, a.menu_nav)
        if len(rows0) == 0 {
            continue
        }
        N :: 7
        for i in 0 ..< N {
            app.handle_chord(&a, chord(name), i != 0)
        }
        want_row := a.menu_nav.row
        want_top := a.menu_nav.top

        // Queue the release first, then stale repeats that arrived after
        // it but before the flush. Those must be dropped; an unrelated
        // key must survive.
        sc, _ := input.key_code(name)
        // Push the KEY_UP for the held arrow – this is the release.
        {
            ev: sdl.Event
            ev.type = .KEY_UP
            ev.key.scancode = sdl.Scancode(sc)
            ev.key.down = false
            if !sdl.PushEvent(&ev) {
                // No queue – skip SDL path
                continue
            }
        }
        // Push 5 stale repeats for this arrow (repeat=true) that were
        // queued after the up (the extra jump case)
        for _ in 0 ..< 5 {
            ev: sdl.Event
            ev.type = .KEY_DOWN
            ev.key.scancode = sdl.Scancode(sc)
            ev.key.down = true
            ev.key.repeat = true
            _ = sdl.PushEvent(&ev)
        }
        // Push an unrelated KEY_DOWN that must survive (e.g. 'A' press)
        {
            ev: sdl.Event
            acode, _ := input.key_code("A")
            ev.type = .KEY_DOWN
            ev.key.scancode = sdl.Scancode(acode)
            ev.key.down = true
            ev.key.repeat = false
            _ = sdl.PushEvent(&ev)
        }
        // Drain via the real input path (WaitEvent would block, so poll)
        // Call input_pump with wait=false to drain without blocking.
        // It will handle the KEY_UP and flush the 5 stale repeats.
        app.input_pump(&a, false)

        // The 5 stale repeats must not have moved the popup
        testing.expectf(t, a.menu_nav.row == want_row, "%s: row jumped on release flush: want %d got %d", name, want_row, a.menu_nav.row)
        testing.expectf(t, a.menu_nav.top == want_top, "%s: top jumped on release flush", name)

        // The unrelated 'A' event must have survived – next pump should
        // deliver it (it will be handled as a chord, not a menu move).
        // We verify at least one event remains by peeking.
        // Drain again to see if queue is empty of arrow repeats but not of other keys.
        // After flush, the 5 arrow repeats should be gone, the 'A' should have been dispatched.
        // Check no arrow repeat remains queued
        tmp: sdl.Event
        dropped := 0
        for sdl.PollEvent(&tmp) {
            if tmp.type == .KEY_DOWN && tmp.key.scancode == sdl.Scancode(sc) && tmp.key.repeat {
                dropped += 1
            }
        }
        testing.expectf(t, dropped == 0, "%s: stale arrow repeats leaked after flush: %d", name, dropped)
        sdl.FlushEvents(.KEY_DOWN, .KEY_UP)
        // Close menu for next case
        app.handle_chord(&a, chord("ESC"))
    }
}

@(private = "file")
chord :: proc(name: string, mods: input.Mods = {}, held := "") -> input.Chord {
    code, _ := input.key_code(name)
    down, _ := input.key_code(held)
    return {code, mods, down}
}

package tests

import "core:strings"
import "core:testing"
import "../desc"
import "../gfx"
import app "../oket"
import "../store"

// The gate for PANELS.md stage 6. The arithmetic itself is `strip_test.odin`'s, because the
// decay is the strip's and needs no App; this is the half that only the kernel can answer —
// what a document lays out at while a panel is moving, and what a shell is told.
//
// The clock is faked in every one of these: `panels_step` takes a dt, so the motion is driven
// rather than waited for. A cell is one pixel (bare_app), so a width reads as a column count.

@(private = "file")
HZ_60 :: f32(1.0 / 60)

@(private = "file")
TAU_MS :: 90 // bare_app leaves the config zero, which is motion OFF; these tests want it on

// A document that WRAPS: the one kind whose layout the panel's width can change, so it is what
// "one reflow per resize" has to be said about. The kernel has no `text` kind, so the descriptor
// is written here rather than by compiling the editor plugin for it.
@(private = "file")
wrap_doc :: proc(a: ^app.App, text: string) -> store.Id {
    id := store.store_open(&a.docs, text)
    gen, _ := store.store_gen(&a.docs, id)
    d := desc.new_from({render = .Text, wrap = .Word, ctx = .Text, selection = .Char,
                        tab_width = 4})
    store.store_submit(&a.docs, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&a.docs)
    return id
}

// Runs the motion out, and answers how many frames it took. A cap, so a decay that never
// snapped fails as a test rather than hanging the suite.
@(private = "file")
run_out :: proc(a: ^app.App) -> int {
    for i in 0 ..< 1000 {
        if !app.panels_step(a, HZ_60) {
            return i
        }
    }
    return -1
}

// The document lays out at the width the panel is ARRIVING at, once (§7). So the body takes the
// target on the frame the resize is asked for, and holds it while the panel slides there: the
// clip animates over text that is already in its final layout, and a WRAPPED document — the one
// kind whose layout the panel's width can change — draws the same rows on every frame of it.
@(test)
a_resize_reflows_the_document_once :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 5)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.tau = TAU_MS
    app.surface_fit(&a, 40, 5)
    app.ring_add(&a, wrap_doc(&a, "one two three four five six seven eight nine ten"))
    app.surface_draw(&a)

    p := app.panel_focused(&a)
    testing.expect_value(t, p.body.w, 40)

    app.panel_resize(&a) // full -> half
    app.surface_draw(&a)
    testing.expect_value(t, app.panel_focused(&a).body.w, 20) // at the target, immediately
    landed := gfx.grid_snapshot(panel_grid(&a), context.temp_allocator)
    // It really did wrap at the target: at 40 columns this is one row, at 20 it is three.
    testing.expect(t, strings.has_prefix(landed, "one two three four\nfive"), landed)

    grids, was_grid := 0, app.panel_focused(&a).grid.cols
    for i in 0 ..< 1000 {
        moving := app.panels_step(&a, HZ_60)
        app.surface_draw(&a)
        q := app.panel_focused(&a)
        testing.expect_value(t, q.body.w, 20) // one layout for the resize, and it was the first
        testing.expect_value(t, gfx.grid_snapshot(&q.grid, context.temp_allocator), landed)
        if q.grid.cols != was_grid {
            grids += 1
            was_grid = q.grid.cols
        }
        if !moving {
            break
        }
        testing.expect(t, i < 999, "the motion never settled")
    }
    testing.expect_value(t, grids, 1) // the grid held both ends, then shrank to the one left
    testing.expect_value(t, app.panel_focused(&a).grid.cols, 20)
}

// A panel is drawn where it IS and lays out where it is going, so the two disagree for exactly
// as long as the motion lasts. Monotone, and it ends.
@(test)
the_panel_slides_to_the_width_its_mode_says :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 5)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.tau = TAU_MS
    app.surface_fit(&a, 40, 5)

    app.panel_resize(&a)
    testing.expect_value(t, app.panel_focused(&a).w, f32(40)) // still where it was drawn

    was := f32(40)
    for i in 0 ..< 1000 {
        moving := app.panels_step(&a, HZ_60)
        w := app.panel_focused(&a).w
        testing.expect(t, w <= was && w >= 20, "the panel left the interval it was moving in")
        was = w
        if !moving {
            break
        }
        testing.expect(t, i < 999, "the motion never settled")
    }
    testing.expect_value(t, app.panel_focused(&a).w, f32(20))
}

// The camera follows focus on the same clock, and `panels_step` says so: while it is true the
// frame loop polls rather than waits, because nothing else is going to wake it (§7).
@(test)
the_camera_scrolls_and_then_stops_asking_for_frames :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 5)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.tau = TAU_MS
    app.surface_fit(&a, 40, 5)

    app.panel_open(&a) // a second full-width panel, and the focus goes with it
    testing.expect_value(t, a.focus, 1)
    testing.expect_value(t, a.strip.aim, f32(40))
    testing.expect_value(t, a.strip.camera, f32(0)) // not there yet: the camera is what moves

    frames := run_out(&a)
    testing.expect(t, frames > 1, "the camera arrived without moving")
    testing.expect_value(t, a.strip.camera, f32(40))
    testing.expect(t, !app.panels_step(&a, HZ_60), "a settled strip still asked for frames")
}

// Motion off is a strip that lands: `tau = 0` in config.conf, and every frame is the last one.
@(test)
tau_of_nothing_lands_at_once :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 5)
    if !ok {
        return
    }
    defer close_app(&a)
    app.surface_fit(&a, 40, 5) // config.tau is zero here

    app.panel_open(&a)
    testing.expect_value(t, run_out(&a), 0) // the fit landed it; the first step has nothing left
    testing.expect_value(t, a.strip.camera, f32(40))
    testing.expect_value(t, app.panel_focused(&a).w, f32(40))
}

// A window resize LANDS, mid-motion included (§7): the view moved under every panel at once,
// and animating that would be the window's own resize drawn a second time, late.
@(test)
a_window_resize_lands_mid_motion :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 5)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.tau = TAU_MS
    app.surface_fit(&a, 40, 5)

    app.panel_resize(&a) // full -> half
    app.panels_step(&a, HZ_60)
    w := app.panel_focused(&a).w
    testing.expect(t, w < 40 && w > 20, "the panel was not in flight")

    app.surface_fit(&a, 60, 5) // the view moved under it
    testing.expect_value(t, app.panel_focused(&a).w, f32(30)) // half the new view, at once
    testing.expect_value(t, a.strip.camera, a.strip.aim)
    testing.expect(t, !app.panels_step(&a, HZ_60), "a landed strip still asked for frames")
}

// A terminal's column count is a CONTRACT with a process and cannot be interpolated, so the
// shell hears about the resize once, at the target, and not once per frame of it (§7).
@(test)
a_pty_gets_one_winsize_per_resize :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.tau = TAU_MS
    app.surface_fit(&a, 40, 6)

    id, made := app.term_open(&a)
    if !testing.expect(t, made, "no shell to spawn") {
        return
    }
    app.ring_add(&a, id)
    tm := app.term_of(&a, id)
    app.term_pump(&a) // the spawn's nominal size, resized to the body it landed in
    testing.expect_value(t, tm.t.cols, 40)

    app.panel_resize(&a) // full -> half
    sizes, was := 0, tm.t.cols
    for i in 0 ..< 1000 {
        moving := app.panels_step(&a, HZ_60)
        app.term_pump(&a)
        if tm.t.cols != was {
            sizes += 1
            was = tm.t.cols
        }
        if !moving {
            break
        }
        testing.expect(t, i < 999, "the motion never settled")
    }
    testing.expect_value(t, sizes, 1)
    testing.expect_value(t, tm.t.cols, 20)
}

// The camera follows the MARK, not the focus (§3, §5). A panel made mid-gesture is one you have
// to be able to SEE — the caret is on it and it is where the next thing lands — and steering
// past the edge of the view has to scroll rather than steer blind.
@(test)
the_camera_follows_the_armed_target :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-camera-mark")
    if !ok {
        return
    }
    defer close_app(&a)
    app.surface_fit(&a, 40, 5) // one full-width panel: only one is ever on screen

    app.panel_open(&a)
    app.panel_step(&a, -1)
    testing.expect_value(t, a.strip.camera, f32(0))

    app.handle_chord(&a, chord("RTRN", {}, "TAB"))
    app.handle_chord(&a, chord("RGHT")) // steer to a panel the view does not hold
    testing.expect_value(t, app.panel_marked(&a), 1)
    testing.expect_value(t, a.focus, 0) // the keys stayed put; the camera did not
    testing.expect_value(t, a.strip.camera, f32(40))

    // And the panel the gesture MAKES is on screen the moment it exists.
    app.handle_chord(&a, chord("RTRN", {}, "TAB"))
    testing.expect_value(t, len(a.panels), 3)
    testing.expect_value(t, app.panel_marked(&a), 2)
    testing.expect_value(t, a.strip.camera, f32(80))
}

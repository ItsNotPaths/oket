package tests

import "core:strings"
import "core:testing"
import "../desc"
import "../gfx"
import "../input"
import "../store"
import app "../oket"

// The column under a held alt (switcher.odin). Alt is not a chord, so the hold is driven here
// the way the window drives it: the modifier's own code, down and then up.

@(private = "file")
lane_doc :: proc(a: ^app.App, file: string) -> store.Id {
    id := store.store_open(&a.docs, "x")
    gen, _ := store.store_gen(&a.docs, id)
    d := desc.new_from({kind = app.KIND_HOME, ctx = .Surface, file = file})
    store.store_submit(&a.docs, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&a.docs)
    return id
}

@(private = "file")
hold :: proc(a: ^app.App, name: string, down: bool) {
    code, _ := input.key_code(name)
    app.switcher_hold(a, code, down)
}

@(private = "file")
alt_down :: proc(a: ^app.App, down: bool) {
    hold(a, "LALT", down)
}

@(private = "file")
drawn_with_alt :: proc(a: ^app.App) -> string {
    alt_down(a, true)
    app.surface_draw(a)
    return gfx.grid_snapshot(panel_grid(a), context.temp_allocator)
}

// The lane, then its live slots in the numbers `alt+N` uses. A closed slot is a gap in the ring
// (ring.odin), so it has to be a gap in the column too: renumbering here would make the picture
// disagree with the key.
@(test)
the_column_names_the_lane_and_keeps_its_gaps :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 12)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, lane_doc(&a, "alpha.txt"))
    app.ring_add(&a, lane_doc(&a, "beta.txt"))
    app.ring_add(&a, lane_doc(&a, "gamma.txt"))
    app.ring_close(&a, 2)
    testing.expect_value(t, app.ring_slot(&a), 3)

    text := drawn_with_alt(&a)
    testing.expect(t, strings.contains(text, "home"), text) // the lane the numbers are of
    testing.expect(t, strings.contains(text, "1  alpha.txt"), text)
    testing.expect(t, strings.contains(text, "3  gamma.txt"), text)
    testing.expect(t, !strings.contains(text, "beta.txt"), text)
    // 2 is gone and 3 did not move up into it.
    testing.expect(t, strings.index(text, "1  alpha.txt") < strings.index(text, "3  gamma.txt"),
                   text)

    // And it is gone the moment alt is.
    alt_down(&a, false)
    app.surface_draw(&a)
    testing.expect(t, !strings.contains(gfx.grid_snapshot(panel_grid(&a), context.temp_allocator),
                                        "alpha.txt"))
}

// `[switcher] show = numbers` is the narrow one: the digits, and not the lane's name either —
// a name would widen the whole column past what it is for.
@(test)
numbers_mode_is_the_digits_alone :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 12)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.switcher = .Numbers

    app.ring_add(&a, lane_doc(&a, "alpha.txt"))
    app.ring_add(&a, lane_doc(&a, "beta.txt"))

    text := drawn_with_alt(&a)
    testing.expect(t, !strings.contains(text, "alpha.txt"), text)
    testing.expect(t, !strings.contains(text, "home"), text)
    for line in strings.split_lines(text, context.temp_allocator) {
        if line == "" {
            continue
        }
        // Two cells of column: a lead and one digit. Anything wider is the titles leaking in.
        testing.expect(t, strings.has_prefix(line, " 1") || strings.has_prefix(line, " 2"), line)
        break
    }
}

// A SIDE of the panel, not a popup over the text: the ground runs to the last row whether or not
// the lane has an entry for it.
@(test)
the_column_runs_the_whole_panel :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 12)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, lane_doc(&a, "alpha.txt"))
    _ = drawn_with_alt(&a)

    g, body := panel_grid(&a), app.panel_focused(&a).body
    ground := app.ground_bg(&a)
    testing.expect_value(t, gfx.grid_at(g, body.x, body.y + body.h - 1).bg, ground)
    // And no wider than it has to be: the cell past the column is the document's own ground.
    testing.expect(t, gfx.grid_at(g, body.w - 1, body.y + body.h - 1).bg != ground)
}

// The hold is a set of alt keys, not one bool: with both alts down, the first release must not
// take the column from the one still held. The last release ends it.
@(test)
the_column_survives_the_first_of_two_alts :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 12)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, lane_doc(&a, "alpha.txt"))
    hold(&a, "LALT", true)
    hold(&a, "RALT", true)
    hold(&a, "LALT", false)
    app.surface_draw(&a)
    text := gfx.grid_snapshot(panel_grid(&a), context.temp_allocator)
    testing.expect(t, strings.contains(text, "alpha.txt"),
                   "the first release took the column from the alt still held")
    hold(&a, "RALT", false)
    testing.expect(t, a.pending == nil, "the last release left the hold pending")
}

// The hold is a DISPLAY state and the pending union frees what it replaces (input/pending.odin).
// Holding alt over an open command line must not take the line's state out from under it.
@(test)
the_hold_never_replaces_another_pending :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 12)
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_show(&a)
    alt_down(&a, true)
    _, still_open := a.pending.(input.Pending_Cmdline)
    testing.expect(t, still_open, "a held alt replaced the command line's pending state")
    alt_down(&a, false)
    _, open_after := a.pending.(input.Pending_Cmdline)
    testing.expect(t, open_after, "alt coming up closed the command line")
}

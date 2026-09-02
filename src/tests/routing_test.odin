package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../desc"
import "../input"
import "../store"
import app "../oket"

// The gate for build order stage 4, end to end: keys and clicks arrive at one funnel, the bind
// table decides, and describe answers for either. The listing from stage 3 is the document under
// test, because it is the one that declares `fields` and selects by row.

// --- the mouse ---

// Pixel to cell is the window's division; from there down a click is a document position, and
// the row it lands on is the row the eye saw.
@(test)
a_click_places_point_on_the_row_under_it :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-click-place")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    app.point_place(&a, 6, 1)
    testing.expect_value(t, point(&a).head.line, 1)

    // The bar is not the document: a click there leaves point where it was.
    app.point_place(&a, 6, a.grid.rows - 1)
    testing.expect_value(t, point(&a).head.line, 1)

    // A drag sweeps from where the press landed.
    app.point_place(&a, 6, 0)
    app.point_drag(&a, 6, 1)
    testing.expect_value(t, point(&a).anchor.line, 0)
    testing.expect_value(t, point(&a).head.line, 1)
}

// §8's promise: a document that declares `fields` gets the mouse by adding one row, and never
// sees an event. The row is the browser's own from the plan.
@(test)
one_row_gives_a_listing_the_mouse :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-click-row")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    app.binds_parse(&a, "[surface]\nclick = exec :open <path>\n", "binds.conf")

    // Hover: the bind table is asked what a click here would do, and the field its line names is
    // the one offered.
    app.hover_update(&a, 2, 1)
    testing.expect(t, a.hover.on, "no hover over the name of a row a click would open")
    testing.expect_value(t, a.hover.line, 1)

    // What is underlined is the NAME, which is the visible tail of the path the line acts on.
    // The two are one span inside the other, and that containment is the whole rule.
    d := store.store_descriptor(&a.docs, app.active(&a).doc)
    defer desc.release(d)
    lo, hi, _ := desc.field_span(d, 1, "name")
    testing.expect_value(t, a.hover.lo, lo)
    testing.expect_value(t, a.hover.hi, hi)

    // Over the size column nothing is offered: the row's line acts on the path, and the size
    // is not part of it.
    app.hover_update(&a, 40, 1)
    testing.expect(t, !a.hover.on)

    // And the hole fills from point, exactly as it would for a key.
    app.point_place(&a, 2, 1)
    line, filled := app.bind_expand(&a, ":open <path>")
    testing.expect(t, filled)
    testing.expect_value(t, line, fmt.tprintf(":open %s/beta.txt", dir))

    // describe answers for the click now, and names the file the row came from.
    answer := input.describe_chord(a.binds[:], {input.mouse_code(.Click), {}}, .Surface, nil)
    defer delete(answer)
    testing.expect_value(
        t,
        answer,
        "click moves point, then runs :open <path>: run as typed [surface, binds.conf:2]",
    )
}

// The wheel is a chord like any other: it resolves through the table and the verb moves the
// viewport, not the caret (§11).
@(test)
the_wheel_scrolls_and_leaves_point_alone :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-wheel")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    app.handle_chord(&a, {input.mouse_code(.Wheel_Down), {}})
    testing.expect_value(t, app.active(&a).view.top, 1)
    testing.expect_value(t, point(&a).head.line, 0)

    // Clamped: the last line stays reachable and the view never runs off the end.
    for _ in 0 ..< 5 {
        app.handle_chord(&a, {input.mouse_code(.Wheel_Down), {}})
    }
    testing.expect_value(t, app.active(&a).view.top, 1) // two entries, so line 1 is the floor
    app.handle_chord(&a, {input.mouse_code(.Wheel_Up), {}})
    testing.expect_value(t, app.active(&a).view.top, 0)
}

// A double-click takes what the descriptor says it takes: a listing selects rows, which is the
// `selection` field deciding rather than a browser writing selection code.
@(test)
a_double_click_selects_at_the_documents_granularity :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-double-click")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    app.point_place(&a, 4, 1)
    app.handle_chord(&a, {input.mouse_code(.Double_Click), {}})
    testing.expect_value(t, point(&a).anchor.line, 1)
    testing.expect_value(t, point(&a).head.line, 1)
    testing.expect_value(t, point(&a).anchor.col, 0)
    testing.expect(t, point(&a).head.col > 0, "the whole row, not a word inside it")
}

// --- keys ---

// The same point the mouse places, moved by the keyboard. A bare arrow answers in a surface, so
// a listing is navigable with no plugin and no surface-specific key code.
@(test)
arrows_move_point_in_a_surface :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-arrows")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    down, _ := input.key_code("DOWN")
    up, _ := input.key_code("UP")

    app.handle_chord(&a, {down, {}})
    testing.expect_value(t, point(&a).head.line, 1)
    app.handle_chord(&a, {down, {}})
    testing.expect_value(t, point(&a).head.line, 1) // the last line is the floor
    app.handle_chord(&a, {up, {}})
    testing.expect_value(t, point(&a).head.line, 0)

    // Shift is not written into the row: it falls back to the bare chord and extends.
    app.handle_chord(&a, {down, {.Shift}})
    testing.expect_value(t, point(&a).anchor.line, 0)
    testing.expect_value(t, point(&a).head.line, 1)
}

// The gate's second half. describe waits for one chord and answers for whatever arrives, and the
// bar shows the wait — a capture the user cannot see is invisible modality.
@(test)
describe_waits_for_one_chord_and_answers :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-describe")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    f1, _ := input.key_code("FK01")
    esc, _ := input.key_code("ESC")

    app.handle_chord(&a, {f1, {}})
    testing.expect(t, a.pending != nil)
    testing.expect(t, strings.contains(app.bar_text(&a), "press any chord"))

    // A click is a chord, so describe answers for one exactly as it does for a key.
    app.handle_chord(&a, {input.mouse_code(.Click), {}})
    testing.expect(t, a.pending == nil)
    testing.expect_value(t, a.message, "click moves point; nothing further is bound")
    testing.expect_value(t, app.bar_text(&a), a.message)

    // Escape cancels the wait rather than answering for Escape.
    app.handle_chord(&a, {f1, {}})
    app.handle_chord(&a, {esc, {}})
    testing.expect(t, a.pending == nil)
    testing.expect(t, !a.quit, "escape cancelled the capture, it did not fall through to quit")
}

// A bound chord that does nothing at all is the one thing §8 exists to prevent, so a verb whose
// stage has not landed reports rather than going quiet.
@(test)
an_unbuilt_verb_says_so :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-unbuilt")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    ctrl_c, _ := input.key_code("AB03")
    app.handle_chord(&a, {ctrl_c, {.Ctrl}})
    testing.expect_value(t, a.message, "edit.copy is not built yet")
}

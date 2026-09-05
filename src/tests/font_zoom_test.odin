package tests

import "core:testing"
import "../font"
import "../gfx"
import "../input"
import app "../oket"

// The zoom changes the ATLAS, not the layout: the frame loop re-fits the grid from
// painter_cell, so a new size relays itself and there is no resize path of its own.
//
// A test builds the atlas by hand. `atlas_resize` touches no GL — it re-bakes in place and
// raises the flag the painter already honours — so everything but the upload runs here.
@(private = "file")
faced_app :: proc(t: ^testing.T, px: int) -> (a: app.App, ok: bool) {
    f, found := font.system_fixed()
    if !found {
        return {}, false // no fonts on this machine; the fallback test below still runs
    }
    defer delete(f.family);defer delete(f.path)

    face, opened := gfx.face_open(f.path, px)
    if !opened {
        return {}, false
    }
    faces := make([]gfx.Face, 1)
    faces[0] = face
    atlas, made := gfx.atlas_make(faces)
    if !testing.expect(t, made, "the atlas would not build over a system face") {
        return {}, false
    }
    a = bare_app() or_return
    a.painter.scale = 1
    a.painter.atlas = atlas
    app.font_init(&a, px)
    return a, true
}

// The gate is the cell WIDTH, the thing face_next_px promises a step always moves.
@(test)
a_zoom_step_moves_the_cell :: proc(t: ^testing.T) {
    a, ok := faced_app(t, 16)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a.painter.atlas)
    defer close_app(&a)

    plus, _ := input.key_code("AE12")
    minus, _ := input.key_code("AE11")
    zero, _ := input.key_code("AE10")

    was, _ := gfx.painter_cell(&a.painter)
    app.handle_chord(&a, {plus, {.Ctrl}, 0})
    bigger, _ := gfx.painter_cell(&a.painter)
    testing.expectf(t, bigger > was, "ctrl+= left the cell at %d", bigger)

    app.handle_chord(&a, {minus, {.Ctrl}, 0})
    back, _ := gfx.painter_cell(&a.painter)
    testing.expect_value(t, back, was)

    // Reset goes to the size the app started at, from wherever the steps left it.
    app.handle_chord(&a, {plus, {.Ctrl}, 0})
    app.handle_chord(&a, {plus, {.Ctrl}, 0})
    app.handle_chord(&a, {zero, {.Ctrl}, 0})
    testing.expect_value(t, a.font_px, 16)

    // And reset from the baseline says so: three bound chords, none of them ever silent.
    app.handle_chord(&a, {zero, {.Ctrl}, 0})
    testing.expect_value(t, a.message, "already at 16 px")
}

// At the ceiling a step has nowhere to go, and it says so instead of going quiet.
@(test)
a_zoom_at_the_range_end_says_so :: proc(t: ^testing.T) {
    a, ok := faced_app(t, gfx.FACE_PX_MAX)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a.painter.atlas)
    defer close_app(&a)

    plus, _ := input.key_code("AE12")
    app.handle_chord(&a, {plus, {.Ctrl}, 0})
    testing.expect_value(t, a.font_px, gfx.FACE_PX_MAX)
    testing.expect(t, len(a.message) > 0, "a zoom at the ceiling went quiet")
}

// The bitmap has one size, and a bound chord that quietly did nothing is what §8 exists to
// prevent. A bare app has no atlas at all, which is the same answer.
@(test)
the_bitmap_fallback_says_it_cannot_zoom :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    plus, _ := input.key_code("AE12")
    app.handle_chord(&a, {plus, {.Ctrl}, 0})
    testing.expect_value(t, a.message,
                         "the built-in bitmap has one size; there is no system font to resize")
}

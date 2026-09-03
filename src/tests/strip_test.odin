package tests

import "core:testing"
import "../strip"

// PANELS.md §9's rule, as a test: the strip is a piece, so this file builds one with a struct
// literal and never reaches for an App. If it ever needs the fixture, the layout has grown a
// dependency on documents and it is not a piece any more.

@(private = "file")
FULL :: [?]strip.Width{.Full, .Full, .Full}

// A strip of one is the whole view, gap or no gap: one-panel mode is a length and not a special
// case (§5), and today's single panel has to land where it always did.
@(test)
a_strip_of_one_is_the_whole_view :: proc(t: ^testing.T) {
    s := strip.Strip {
        view = 100,
        gap  = 10,
    }
    one := [?]strip.Width{.Full}
    it := strip.span(s, one[:], 0)
    testing.expect_value(t, it.x, f32(0))
    testing.expect_value(t, it.w, f32(100))
}

// Two halves are worth one full: the slots tile the view exactly, and the gap comes out of the
// two panels that meet at it, half each. So both are the same width and neither end is inset.
@(test)
two_halves_tile_the_view_with_one_gap_between :: proc(t: ^testing.T) {
    s := strip.Strip {
        view = 100,
        gap  = 10,
    }
    half := [?]strip.Width{.Half, .Half}
    a, b := strip.span(s, half[:], 0), strip.span(s, half[:], 1)
    testing.expect_value(t, a, strip.Span{0, 45})
    testing.expect_value(t, b, strip.Span{55, 45})
    testing.expect_value(t, b.x - (a.x + a.w), f32(10)) // one gap, and it is the whole of it
}

// The camera follows focus and moves by the least it can: a panel already on screen does not
// scroll the strip, and neither end can be passed.
@(test)
the_camera_moves_by_the_least_it_can :: proc(t: ^testing.T) {
    s := strip.Strip{view = 100}
    widths := FULL

    testing.expect_value(t, strip.look_at(s, widths[:], 0), f32(0))
    testing.expect_value(t, strip.look_at(s, widths[:], 2), f32(200))

    s.camera = 200
    testing.expect_value(t, strip.look_at(s, widths[:], 2), f32(200)) // already there
    testing.expect_value(t, strip.look_at(s, widths[:], 1), f32(100))

    s.camera = 9999 // past the end, whatever asked for it
    testing.expect_value(t, strip.look_at(s, widths[:], 2), f32(200))
}

// A column number means nothing until this has answered (§7). A pixel in a gap belongs to no
// panel, and so does one past the last.
@(test)
a_pixel_is_in_a_panel_or_in_no_panel :: proc(t: ^testing.T) {
    s := strip.Strip {
        view = 100,
        gap  = 10,
    }
    half := [?]strip.Width{.Half, .Half}
    testing.expect_value(t, strip.hit(s, half[:], 0), 0)
    testing.expect_value(t, strip.hit(s, half[:], 44), 0)
    testing.expect_value(t, strip.hit(s, half[:], 50), -1) // the gap
    testing.expect_value(t, strip.hit(s, half[:], 55), 1)
    testing.expect_value(t, strip.hit(s, half[:], 99), 1)
    testing.expect_value(t, strip.hit(s, half[:], 200), -1)
}

// The strip scrolled: a panel left of the camera draws at a negative origin, which is what the
// clip is for, and the hit test says so rather than folding it onto column 0.
@(test)
a_panel_left_of_the_camera_has_a_negative_origin :: proc(t: ^testing.T) {
    s := strip.Strip {
        view   = 100,
        camera = 200,
    }
    widths := FULL
    testing.expect_value(t, strip.span(s, widths[:], 0), strip.Span{-200, 100})
    testing.expect_value(t, strip.span(s, widths[:], 2), strip.Span{0, 100})
    testing.expect_value(t, strip.hit(s, widths[:], 10), 2)
    testing.expect_value(t, strip.total(s, widths[:]), f32(300))
}

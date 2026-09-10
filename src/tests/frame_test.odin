package tests

import "core:testing"
import "../strip"
import app "../oket"

// CHROME.md §11, which nothing gated. The frame solves in PIXELS and the kernel writes in CELLS,
// so every rect crosses back through a snap that rounds both EDGES of a rect rather than its
// width. `panel_cols`' `ceil` is what that replaced, and a width rounded on its own is what it
// must not become.

// A cell wide enough that a third of the view does not land on one, which is the case the snap
// exists for. Rows are exact by construction: the solve's window is whole cells either way.
@(private = "file")
CELL :: [2]int{8, 12}

// 320 pixels over three panels is 106.667 each, or 13.333 cells. Rounding each WIDTH answers
// 13+13+13 and loses a column off the end of the strip; `ceil` answers 14+14+14 and invents two.
// Rounding the shared edges answers 13+14+13, which is the view.
@(test)
three_panels_tile_the_view_in_whole_cells :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 10)
    if !ok {
        return
    }
    defer close_app(&a)
    app.panel_make(&a, 1)
    app.panel_make(&a, 2)
    for &p in a.panels {
        p.size = app.WIDTH_FULL / 3
    }
    app.surface_fit(&a, 40, 10, CELL)

    cols := 0
    for &p in a.panels {
        cols += p.body.w
    }
    testing.expect_value(t, a.frame.body.w, 40)
    testing.expect_value(t, cols, 40)
}

// The mechanism on its own, so a failure above says which half broke: a shared edge rounds ONCE,
// so neither slot can gain the column the other lost.
@(test)
a_shared_edge_rounds_once :: proc(t: ^testing.T) {
    left := strip.Span{0, 106.667}
    right := strip.Span{106.667, 106.666}
    testing.expect_value(t, app.frame_cols(left, CELL.x), 13)
    testing.expect_value(t, app.frame_cols(right, CELL.x), 14)
}

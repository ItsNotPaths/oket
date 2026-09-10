package tests

import "core:testing"
import "../gfx"
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

// CHROME.md §13.3. The ground grid is drawn OVER the frame's pass, so every cell of it off the
// bar's row says NOTHING: a colour anywhere else covers the frame one call after it drew.
@(test)
the_ground_covers_nothing_but_the_bar :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 10)
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    // Both ways the row is written: the resting line, and the command line that replaces it.
    for open in ([2]bool{false, true}) {
        if open {
            app.handle_chord(&a, chord("AB03", {.Alt})) // alt+c
            testing.expect(t, app.cl_active(&a), "the second pass is not the second path")
        }
        app.surface_draw(&a)
        lo, hi := solid_rows(&a.ground)
        testing.expect_value(t, lo, a.frame.bar.y)
        testing.expect_value(t, hi, a.frame.bar.y)
    }
}

// The first and last row holding a cell that would cover the frame; -1, -1 for a grid with none.
@(private = "file")
solid_rows :: proc(g: ^gfx.Grid) -> (lo, hi: int) {
    lo, hi = -1, -1
    for y in 0 ..< g.rows {
        for x in 0 ..< g.cols {
            if gfx.grid_at(g, x, y).bg != gfx.NOTHING {
                if lo < 0 {
                    lo = y
                }
                hi = y
                break
            }
        }
    }
    return
}

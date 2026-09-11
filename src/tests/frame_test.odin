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

// CHROME.md §15 stage 6. The frame's pass runs AFTER the panels, so the strip's ground is the
// GAPS: one rect before the first panel, one between each pair, and one past the last. A rect
// spanning the strip would cover the documents.
@(test)
the_strips_ground_is_the_gaps :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 10)
    if !ok {
        return
    }
    defer close_app(&a)
    app.panel_make(&a, 1)
    for &p in a.panels {
        p.size = app.WIDTH_FULL / 2
    }
    a.config.gap = 4
    app.surface_fit(&a, 40, 10, CELL)

    ss := app.panel_spans(&a)
    gaps := app.ground_gaps(&a, 0, 0, ss)
    testing.expect_value(t, len(gaps), 3) // two ends and the one gap between them

    left, right := strip.span(a.strip, ss, 0), strip.span(a.strip, ss, 1)
    testing.expect_value(t, gaps[0].w, left.x - a.frame.strip.x) // flush against the strip's end
    testing.expect_value(t, gaps[1].x, left.x + left.w)
    testing.expect_value(t, gaps[1].w, right.x - (left.x + left.w))
    testing.expect_value(t, gaps[2].x, right.x + right.w)
    // One gradient down all of them: each keeps the strip's own y and h, so no seam shows.
    for g in gaps {
        testing.expect_value(t, g.y, a.frame.strip.y)
        testing.expect_value(t, g.h, a.frame.strip.h)
    }
}

// CHROME.md §13.3 and §15 stage 5. The ground grid is drawn OVER the frame's pass, so a cell
// of it that paints a colour is a frame pixel covered one call later. At rest it covers NOTHING
// AT ALL, because the bar's row is a box. An open command line is the one thing that fills a
// row of it.
@(test)
the_ground_covers_nothing_but_an_open_line :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 10)
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    app.surface_draw(&a)
    lo, hi := solid_rows(&a.ground)
    testing.expect_value(t, lo, -1)
    testing.expect_value(t, hi, -1)

    app.handle_chord(&a, chord("AB03", {.Alt})) // alt+c
    testing.expect(t, app.cl_active(&a), "the second pass is not the second path")
    app.surface_draw(&a)
    lo, hi = solid_rows(&a.ground)
    testing.expect_value(t, lo, a.frame.bar.y)
    testing.expect_value(t, hi, a.frame.bar.y)
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

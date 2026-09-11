package tests

import "core:testing"
import "../gfx"
import "../strip"
import app "../oket"

// CHROME.md §11. The frame solves in PIXELS against the WINDOW, so its edges are not cell
// edges: the menubar sits on the top one and the bar on the bottom one. A pane FLOORS the
// cells of text it holds and CEILS the cells of its grid, so no glyph is clipped, no pixel
// goes uncovered, and the difference is the pane's own background.

// A cell wide enough that a third of the view does not land on one, and a window that does
// not divide into rows, which is the case the floor and the ceil exist for.
@(private = "file")
CELL :: [2]int{8, 12}

// 320 pixels over three panes is 106.667 each, or 13.333 cells. The text floors to 13 columns
// and keeps the pane's left edge; the grid ceils to 14, so the pane's own background covers the
// column the text does not reach and the strip loses no pixel to its ends. 103 pixels of height
// do the same to the rows.
@(test)
three_panes_pin_their_text_and_cover_their_spans :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.panel_make(&a, 1)
    app.panel_make(&a, 2)
    for &p in a.panels {
        p.size = app.WIDTH_FULL / 3
    }
    app.surface_fit(&a, 320, 115, CELL)

    testing.expect_value(t, a.frame.body.w, 40)
    for &p in a.panels {
        testing.expect_value(t, p.body.w, 13)
        testing.expect_value(t, p.grid.cols, 14)
        testing.expect_value(t, p.body.h, 8)
        testing.expect_value(t, p.grid.rows, 9)
    }
}

// The mechanism on its own, so a failure above says which half broke: the run floors into
// text and ceils into coverage, so a glyph is never clipped and no pixel is left uncovered.
@(test)
a_run_floors_its_text_and_ceils_its_cover :: proc(t: ^testing.T) {
    testing.expect_value(t, app.frame_cols(106.667, CELL.x), 13)
    testing.expect_value(t, app.frame_cover(106.667, CELL.x), 14)
    testing.expect_value(t, app.frame_cols(104.0, CELL.x), 13)
    testing.expect_value(t, app.frame_cover(104.0, CELL.x), 13)
}

// The small end: a strip that holds less than one cell floors the text to nothing and ceils
// the cover to one, so the pane is a sliver of its own background and nothing faults.
@(test)
a_pane_smaller_than_a_cell_holds_no_text :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.surface_fit(&a, 5, 20, CELL)

    p := app.panel_focused(&a)
    testing.expect_value(t, p.body.w, 0)
    testing.expect_value(t, p.body.h, 0)
    testing.expect_value(t, p.grid.cols, 1)
    testing.expect_value(t, p.grid.rows, 1)
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
    app.surface_fit(&a, 320, 120, CELL)

    ss := app.panel_spans(&a)
    gaps := app.ground_gaps(&a, ss)
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

// CHROME.md §13.3 and §15 stage 5. The bar's grid is drawn OVER the frame's pass, so a cell
// of it that paints a colour is a frame pixel covered one call later. At rest it covers
// NOTHING AT ALL, because the bar's row is a box. An open command line is the one thing that
// fills its one row.
@(test)
the_bar_covers_nothing_but_an_open_line :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 10)
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    app.surface_draw(&a)
    lo, hi := solid_rows(&a.bar_grid)
    testing.expect_value(t, lo, -1)
    testing.expect_value(t, hi, -1)

    app.handle_chord(&a, chord("AB03", {.Alt})) // alt+c
    testing.expect(t, app.cl_active(&a), "the second pass is not the second path")
    app.surface_draw(&a)
    lo, hi = solid_rows(&a.bar_grid)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 0)
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

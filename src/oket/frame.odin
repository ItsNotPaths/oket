package main

import "core:math"
import "../gfx"
import "../lay"

// The frame's geometry, and the ONE place it is computed (CHROME.md §2.1). Every rect outside a
// document comes out of one `lay.solve` here: the rows a menubar keeps, the command line's row,
// the window the panels sit in, and the slot each panel rests in. Six sites used to each answer
// a piece of this, and none of them agreed.
//
// What is NOT here is motion. The solve answers the RESTING layout; `strip.approach` walks a
// panel between two of them on the clock, and the camera is an offset applied to what came out
// (PANELS.md §7). One layouter, one animator, and neither does the other's job.
//
// TWO LATTICES, NOT ONE (PANELS.md §7). The solve is in PIXELS, because a gap, a half width
// and a camera are pixels. What the kernel WRITES into is cells, so the WINDOW is the solve's
// root and not a whole number of them (§11): the menubar sits on the top edge, the bar on the
// bottom one, and the pixels the cells cannot split stay inside the strip, under the panes.

// The frame's boxes, in the order `lay` wants them: a parent is always earlier in the array.
@(private = "file")
ROOT :: 0
@(private = "file")
MENU :: 1
@(private = "file")
STRIP :: 2
@(private = "file")
BAR :: 3
@(private = "file")
SLOT :: 4 // one per panel, from here on

Frame :: struct {
    // The menubar's reserved rows, and the strip's text area in cells under them.
    menu:  int,
    body:  Cells,
    // The bar's box and the strip: pixels, which the camera and every slot count from.
    bar:   gfx.Rect,
    strip: gfx.Rect,
}

// The frame, solved into `a.frame`, and where each panel RESTS onto the panel itself. One call,
// because the three rects and the slots come out of the same solve.
frame_fit :: proc(a: ^App, win_w, win_h: int) {
    panels_ready(a)
    cell := a.cell
    boxes := make([]lay.Box, SLOT + len(a.panels), context.temp_allocator)
    boxes[ROOT] = {parent = -1, dir = .Col}
    // A hidden menubar is a box of NO ROWS rather than a branch, which is the whole of what
    // `constant` costs: opening it reflows a document and closing it puts every row back
    // (MENU.md §4).
    rows := menu_rows(a)
    boxes[MENU] = {parent = ROOT, size = lay.px(f32(rows * cell.y))}
    // The gap is the row's, not the panels' — half off each side of the edge two of them meet
    // at, so the strip's own ends stay flush (PANELS.md §5). src/lay does that for any row.
    boxes[STRIP] = {parent = ROOT, size = lay.grow(), dir = .Row, gap = f32(a.config.gap)}
    boxes[BAR] = {parent = ROOT, size = lay.px(f32(cell.y))}
    // A share, and never a width: what a percent is worth is the view it is a percent OF, and
    // that is the strip's content — which is the one thing the solve knows and this does not.
    for p, i in a.panels {
        boxes[SLOT + i] = {parent = STRIP, size = lay.share(f32(p.size) / WIDTH_FULL)}
    }
    lay.solve(boxes, {0, 0, f32(win_w), f32(win_h)})

    st := boxes[STRIP].rect
    a.frame = {
        menu  = rows,
        body  = {0, rows, frame_cols(st.w, cell.x), frame_cols(st.h, cell.y)},
        bar   = boxes[BAR].rect,
        strip = st,
    }
    for &p, i in a.panels {
        p.dest = {boxes[SLOT + i].rect.x, boxes[SLOT + i].rect.w}
    }
}

// The text cells a run holds: FLOORED, so the text is pinned to the pane's top-left and no
// glyph is ever clipped (§11).
frame_cols :: proc(run: f32, cell: int) -> int {
    return cell > 0 ? max(int(run / f32(cell)), 0) : 0
}

// The cells a pane's GRID holds: the same run CEILED, so the pane's own background covers
// every pixel of it and the spare row or column clips at the pane's edge (§11).
frame_cover :: proc(run: f32, cell: int) -> int {
    if cell <= 0 {
        return 0
    }
    return max(int(math.ceil(run / f32(cell))), 0)
}

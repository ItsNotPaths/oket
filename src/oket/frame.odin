package main

import "core:math"
import "../gfx"
import "../lay"
import "../strip"

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
// and a camera are pixels. What the kernel WRITES into is cells, so what comes back is snapped
// (§11) — and the snap rounds both EDGES of a rect rather than its width, which is what keeps
// two slots that touch touching and the strip tiling the view exactly.

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
    // The ground's cells: the two rows the kernel writes into, and the window the panels sit in.
    menu:  Cells,
    body:  Cells,
    bar:   Cells,
    // The same strip in pixels, which is what the camera and every slot count from.
    strip: gfx.Rect,
}

// The frame, solved into `a.frame`, and where each panel RESTS onto the panel itself. One call,
// because the three rects and the slots come out of the same solve.
frame_fit :: proc(a: ^App, cols, rows: int) {
    panels_ready(a)
    cell := a.cell
    boxes := make([]lay.Box, SLOT + len(a.panels), context.temp_allocator)
    boxes[ROOT] = {parent = -1, dir = .Col}
    // A hidden menubar is a box of NO ROWS rather than a branch, which is the whole of what
    // `constant` costs: opening it reflows a document and closing it puts every row back
    // (MENU.md §4).
    boxes[MENU] = {parent = ROOT, size = lay.px(f32(menu_rows(a) * cell.y))}
    // The gap is the row's, not the panels' — half off each side of the edge two of them meet
    // at, so the strip's own ends stay flush (PANELS.md §5). src/lay does that for any row.
    boxes[STRIP] = {parent = ROOT, size = lay.grow(), dir = .Row, gap = f32(a.config.gap)}
    boxes[BAR] = {parent = ROOT, size = lay.px(f32(cell.y))}
    // A share, and never a width: what a percent is worth is the view it is a percent OF, and
    // that is the strip's content — which is the one thing the solve knows and this does not.
    for p, i in a.panels {
        boxes[SLOT + i] = {parent = STRIP, size = lay.share(f32(p.size) / WIDTH_FULL)}
    }
    lay.solve(boxes, {0, 0, f32(cols * cell.x), f32(rows * cell.y)})

    a.frame = {
        menu  = frame_cells(boxes[MENU].rect, cell),
        body  = frame_cells(boxes[STRIP].rect, cell),
        bar   = frame_cells(boxes[BAR].rect, cell),
        strip = boxes[STRIP].rect,
    }
    for &p, i in a.panels {
        p.dest = {boxes[SLOT + i].rect.x, boxes[SLOT + i].rect.w}
    }
}

// A pixel rect in whole cells (§11). BOTH EDGES round, so two rects that touch still touch, and
// the remainder is what the rounding hands out — there is no second pass to distribute it.
frame_cells :: proc(r: gfx.Rect, cell: [2]int) -> Cells {
    x, y := cell_at(r.x, cell.x), cell_at(r.y, cell.y)
    return {x, y, max(cell_at(r.x + r.w, cell.x) - x, 0), max(cell_at(r.y + r.h, cell.y) - y, 0)}
}

// And back: a rect the solve answered in CELLS, on screen. §11's snap is what makes this exact
// — every frame rect is a whole number of cells by the time anyone asks. A CARET is not one of
// these: it lands on a panel that has slid, so its origin carries the strip's fraction with it
// (surface.odin, caret_px).
frame_px :: proc(r: Cells, origin, cell: [2]int) -> gfx.Rect {
    return {f32(origin.x + r.x * cell.x), f32(origin.y + r.y * cell.y),
            f32(r.w * cell.x), f32(r.h * cell.y)}
}

// The columns a slot holds, by the same rounding. This is what `panel_cols`'s `ceil` was: a rect
// that arrives cell-aligned has no remainder left to round, so the half glyph is gone from every
// resting state and stays only in the motion between two of them (§11).
frame_cols :: proc(it: strip.Span, cell_w: int) -> int {
    return max(cell_at(it.x + it.w, cell_w) - cell_at(it.x, cell_w), 0)
}

@(private = "file")
cell_at :: proc(px: f32, cell: int) -> int {
    return cell > 0 ? int(math.round(px / f32(cell))) : 0
}

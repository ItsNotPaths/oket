package main

import "core:math"
import "../gfx"
import "../strip"

// The frame in pixels (CHROME.md §2.1): menubar rows on the top edge, the bar's row on the
// bottom one, the strip between, and where each panel rests in it. Motion is strip's, not this.

Frame :: struct {
    // The menubar's reserved rows, and the strip's text area in cells under them.
    menu:  int,
    body:  Cells,
    // The bar's box and the strip: pixels, which the camera and every slot count from.
    bar:   gfx.Rect,
    strip: gfx.Rect,
}

frame_fit :: proc(a: ^App, win_w, win_h: int) {
    panels_ready(a)
    cell := a.cell
    rows := menu_rows(a)
    top := f32(rows * cell.y)
    st := gfx.Rect{0, top, f32(win_w), max(f32(win_h) - top - f32(cell.y), 0)}
    a.frame = {
        menu  = rows,
        body  = {0, rows, frame_cols(st.w, cell.x), frame_cols(st.h, cell.y)},
        bar   = {0, st.y + st.h, f32(win_w), f32(cell.y)},
        strip = st,
    }
    // A width is a share of the strip, so shares past one scroll rather than shrink.
    along := st.x
    for &p, i in a.panels {
        run := f32(p.size) / WIDTH_FULL * st.w
        p.dest = strip.slot(along, run, f32(a.config.gap), i, len(a.panels))
        along += run
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

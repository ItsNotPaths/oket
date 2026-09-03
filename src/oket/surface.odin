package main

import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"

// The kernel's frame: the ring's focused document in the panel, the bar on the chrome's last
// row. With nothing focused the panel falls through to the kernel screen, which is what that
// floor exists for (§7, §13).
//
// Two grids, drawn in two calls (PANELS.md §7). The chrome is the screen lattice and the panel
// is a window onto a document, so a panel that is narrower than the screen, or standing at a
// fractional origin, costs an origin and a clip here and nothing anywhere below.

// The chrome is the whole fit; the panel is everything above the bar. A one-row window leaves
// no panel, and a grid of no rows draws nothing.
surface_fit :: proc(a: ^App, cols, rows: int) {
    gfx.grid_resize(&a.chrome, cols, rows)
    gfx.grid_resize(&a.panel, cols, max(rows - 1, 0))
}

surface_draw :: proc(a: ^App) {
    ch, pn, th := &a.chrome, &a.panel, a.theme
    row := max(ch.rows - 1, 0)
    a.body = {0, 0, pn.cols, pn.rows}
    a.bar = {len(CL_PROMPT), row, max(ch.cols - len(CL_PROMPT), 0), 1}

    gfx.grid_clear(ch, th[.Fg], th[.Bg])
    // The bar is the frame's row (§11), over whatever is below it — the kernel screen included.
    // While the command line is open it IS the bar: a state the user cannot see is the thing
    // §1 exists to kill, and the line is its own label.
    defer if cl_active(a) {
        cl_draw(a, ch, th)
    } else {
        gfx.grid_write(ch, 0, row, bar_text(a), th[.Dim], th[.Bg])
    }

    s := ring_focused(&a.ring)
    snap := s != nil ? store.store_snapshot(&a.docs, s.doc) : nil
    if snap == nil {
        screen_draw(pn, th, &a.painter.atlas)
        return
    }
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, s.doc) // the id just resolved, so this cannot miss
    defer desc.release(d)

    gfx.grid_clear(pn, th[.Fg], th[.Bg])

    b := a.body
    view.draw(pn, th, &snap.text, d, s.view, b.x, b.y, b.w, b.h,
              doc_styles(a, s.doc, &snap.text, s.view.top, b.h))
    if a.hover.on {
        view.underline(pn, &snap.text, d, s.view, b.x, b.y, b.w, b.h,
                       a.hover.line, a.hover.lo, a.hover.hi)
    }
}

// The frame, on the GPU: the chrome, then the panel over it. Both take the centred origin the
// painter computes, because one panel starts at the screen's own corner.
surface_paint :: proc(a: ^App, win_w, win_h: i32) {
    p := &a.painter
    ox, oy := gfx.painter_origin(p, win_w, win_h, a.chrome.cols, a.chrome.rows)
    cw, ch := gfx.painter_cell(p)
    o := [2]f32{f32(ox), f32(oy)}
    gfx.painter_draw(p, &a.chrome, win_w, win_h, o, {0, 0, win_w, win_h})
    gfx.painter_draw(p, &a.panel, win_w, win_h, o,
                     {i32(ox), i32(oy), i32(a.panel.cols * cw), i32(a.panel.rows * ch)})
}

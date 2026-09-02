package main

import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"

// The kernel's frame: the ring's focused document in the body, the bar on the last row. With
// nothing focused it falls through to the kernel screen, which is what that floor exists for
// (§7, §13).
surface_draw :: proc(a: ^App) {
    g, th := &a.grid, a.theme
    row := max(g.rows - 1, 0)
    a.body = {0, 0, g.cols, row}
    a.bar = {len(CL_PROMPT), row, max(g.cols - len(CL_PROMPT), 0), 1}
    // The bar is the frame's row (§11), over whatever is below it — the kernel screen included.
    // While the command line is open it IS the bar: a state the user cannot see is the thing
    // §1 exists to kill, and the line is its own label.
    defer if cl_active(a) {
        cl_draw(a, g, th)
    } else {
        gfx.grid_write(g, 0, row, bar_text(a), th[.Dim], th[.Bg])
    }

    s := ring_focused(&a.ring)
    snap := s != nil ? store.store_snapshot(&a.docs, s.doc) : nil
    if snap == nil {
        screen_draw(g, th, &a.painter.atlas)
        return
    }
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, s.doc) // the id just resolved, so this cannot miss
    defer desc.release(d)

    gfx.grid_clear(g, th[.Fg], th[.Bg])

    b := a.body
    view.draw(g, th, &snap.text, d, s.view, b.x, b.y, b.w, b.h,
              doc_styles(a, s.doc, &snap.text, s.view.top, b.h))
    if a.hover.on {
        view.underline(g, &snap.text, d, s.view, b.x, b.y, b.w, b.h,
                       a.hover.line, a.hover.lo, a.hover.hi)
    }
}

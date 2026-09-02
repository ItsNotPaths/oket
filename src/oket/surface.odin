package main

import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"

// The kernel's frame: one document in the body, the bar on the last row. Stage 5's ring turns
// the single surface here into a lane; nothing else about this changes. With no document to
// draw it falls through to the kernel screen, which is what that floor exists for (§7, §13).
surface_draw :: proc(a: ^App) {
    g, th := &a.grid, a.theme
    a.body = {0, 0, g.cols, max(g.rows - 1, 0)}
    // The bar is the frame's row (§11), over whatever is below it — the kernel screen included.
    defer gfx.grid_write(g, 0, g.rows - 1, bar_text(a), th[.Dim], th[.Bg])

    snap := store.store_snapshot(&a.docs, a.id)
    if snap == nil {
        screen_draw(g, th, &a.painter.atlas)
        return
    }
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, a.id) // the id just resolved, so this cannot miss
    defer desc.release(d)

    gfx.grid_clear(g, th[.Fg], th[.Bg])

    b := a.body
    view.draw(g, th, &snap.text, d, a.view, b.x, b.y, b.w, b.h)
    if a.hover.on {
        view.underline(g, &snap.text, d, a.view, b.x, b.y, b.w, b.h,
                       a.hover.line, a.hover.lo, a.hover.hi)
    }
}

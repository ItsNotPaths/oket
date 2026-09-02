package main

import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"

// The kernel's frame: one document in the body, the bar on the last row. Stage 5's ring turns
// the single surface here into a lane; nothing else about this changes. With no document to
// draw it falls through to the kernel screen, which is what that floor exists for (§7, §13).
surface_draw :: proc(
    g: ^gfx.Grid,
    th: gfx.Theme,
    a: ^gfx.Atlas,
    s: ^store.Store,
    id: store.Id,
    v: view.View,
) {
    snap := store.store_snapshot(s, id)
    if snap == nil {
        screen_draw(g, th, a)
        return
    }
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(s, id) // the id just resolved, so this cannot miss
    defer desc.release(d)

    gfx.grid_clear(g, th[.Fg], th[.Bg])

    view.draw(g, th, &snap.text, d, v, 0, 0, g.cols, g.rows - 1)
    gfx.grid_write(g, 0, g.rows - 1, bar_text(), th[.Dim], th[.Bg])
}

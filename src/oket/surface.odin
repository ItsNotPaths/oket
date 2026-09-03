package main

import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"

// The kernel's frame: the strip's documents in their panels, the bar on the chrome's last row.
// A panel standing on nothing falls through to the kernel screen, which is what that floor
// exists for (§7, §13).
//
// One grid per panel plus the chrome, drawn in a call each (PANELS.md §7). The chrome is the
// screen lattice and a panel is a window onto a document, so a panel that is narrower than the
// screen, or standing at a fractional origin, costs an origin and a clip here and nothing
// anywhere below.

// The chrome is the whole fit; the strip gets everything above the bar.
surface_fit :: proc(a: ^App, cols, rows: int) {
    gfx.grid_resize(&a.chrome, cols, rows)
    panels_fit(a, cols, rows)
}

surface_draw :: proc(a: ^App) {
    ch, th := &a.chrome, a.theme
    row := max(ch.rows - 1, 0)
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

    for &p in a.panels {
        panel_draw(a, &p)
    }
}

// One panel, into its own grid and its own cells. The rectangle is recorded before the document
// is: a click is placed against it, and a panel with nothing in it still has a height.
@(private = "file")
panel_draw :: proc(a: ^App, p: ^Panel) {
    th := a.theme
    p.body = {0, 0, p.grid.cols, p.grid.rows}

    s := panel_slot(a, p)
    snap := s != nil ? store.store_snapshot(&a.docs, s.doc) : nil
    if snap == nil {
        screen_draw(&p.grid, th, &a.painter.atlas)
        return
    }
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, s.doc) // the id just resolved, so this cannot miss
    defer desc.release(d)

    gfx.grid_clear(&p.grid, th[.Fg], th[.Bg])

    b := p.body
    view.draw(&p.grid, th, &snap.text, d, s.view, b.x, b.y, b.w, b.h,
              doc_styles(a, s.doc, &snap.text, s.view.top, b.h))
    if p.hover.on {
        view.underline(&p.grid, &snap.text, d, s.view, b.x, b.y, b.w, b.h,
                       p.hover.line, p.hover.lo, p.hover.hi)
    }
}

// The frame, on the GPU: the chrome, then every panel over it. A panel's origin is the chrome's
// plus its own corner, in whole cells while the strip is one long.
surface_paint :: proc(a: ^App, win_w, win_h: i32) {
    p := &a.painter
    ox, oy := gfx.painter_origin(p, win_w, win_h, a.chrome.cols, a.chrome.rows)
    cw, ch := gfx.painter_cell(p)
    gfx.painter_draw(p, &a.chrome, win_w, win_h, {f32(ox), f32(oy)}, {0, 0, win_w, win_h})
    for &pn, i in a.panels {
        r := panel_screen(a, i)
        x, y := i32(ox + r.x * cw), i32(oy + r.y * ch)
        gfx.painter_draw(p, &pn.grid, win_w, win_h, {f32(x), f32(y)},
                         {x, y, i32(r.w * cw), i32(r.h * ch)})
    }
}

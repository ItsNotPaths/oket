package main

import "../desc"
import "../gfx"
import "../store"
import "../strip"
import "../txt"
import "../view"

// The kernel's frame: the strip's documents in their panels, the bar on the ground's last row.
// A panel standing on nothing falls through to the kernel screen, which is what that floor
// exists for (§7, §13).
//
// One grid per panel plus the ground, drawn in a call each (PANELS.md §7). The ground is the
// screen lattice and a panel is a window onto a document, so a panel that is narrower than the
// screen, or standing at a fractional origin, costs an origin and a clip here and nothing
// anywhere below.

// The surface the panels sit on, and the window's own margins with it: one answer, so a gap and
// the edge past the strip cannot end up two colours. Darker than a panel, so the strip reads as
// documents sitting ON something rather than as holes cut in one surface.
ground_bg :: proc(a: ^App) -> [3]f32 {
    return gfx.theme_behind(a.theme, a.config.behind)
}

// The ground is the whole fit; the strip gets everything above the bar. The cell size comes in
// because the strip is pixels and the grids are cells (§7); a caller with no painter leaves a
// cell one pixel, and its strip arithmetic then reads in columns.
surface_fit :: proc(a: ^App, cols, rows: int, cell := [2]int{1, 1}) {
    a.cell = cell
    gfx.grid_resize(&a.ground, cols, rows)
    panels_fit(a, cols, rows)
}

surface_draw :: proc(a: ^App) {
    g, th := &a.ground, a.theme
    // The row the frame's solve kept for it, and never `rows - 1` counted here (frame.odin).
    row := a.frame.bar.y
    a.bar = {len(CL_PROMPT), row, max(a.frame.bar.w - len(CL_PROMPT), 0), 1}

    // NOTHING, not a colour: what a gap shows through is the FRAME's ground, and this grid is
    // painted over it (§13.3). The bar's row is the only thing written into it.
    gfx.grid_clear(g, th[.Fg], gfx.NOTHING)
    // The bar is the frame's row (§11), over whatever is below it — the kernel screen included.
    // While the command line is open it IS the bar: a state the user cannot see is the thing
    // §1 exists to kill, and the line is its own label.
    // THE ROW CHANGES TEXTURE WHEN YOU OPEN IT, which is the state made visible: at rest the
    // cells say NOTHING and the frame's box shows, and the line fills the row flat. A raw text
    // field on a gradient strip is what an entry looks like.
    defer if cl_active(a) {
        cl_draw(a, g, th)
    } else {
        gfx.grid_write(g, 0, row, bar_text(a), bar_theme(th)[.Dim], gfx.NOTHING)
    }

    for &p, i in a.panels {
        panel_draw(a, &p, i == panel_marked(a))
    }
    switcher_draw(a) // into the focused panel's grid, over what it just drew
    menubar_draw(a) // its own grids, after the panels (MENU.md §4)
}

// One panel, into its own grid and its own cells. The rectangle it draws into is the FIT's, and
// it is the width the panel is arriving at rather than the one on screen this frame (§7): the
// document lays out once per resize and the clip animates over it.
//
// THE CARET IS WHAT SAYS WHICH PANEL THE NEXT THING LANDS IN (§3). Reverse video in a panel the
// keys are not aimed at would be the surface lying about where the next keystroke goes, and the
// lane `alt+N` addresses is the focused panel's — so which one that is has to be on screen. It
// is the armed picker's TARGET while one is armed, which is what makes steering visible with no
// second mark to invent (PANELS.md §6).
@(private = "file")
panel_draw :: proc(a: ^App, p: ^Panel, marked: bool) {
    th := a.theme
    s := panel_slot(a, p)
    snap := s != nil ? store.store_snapshot(&a.docs, s.doc) : nil
    if snap == nil {
        screen_draw(&p.grid, th, &a.painter.atlas)
        return
    }
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, s.doc) // the id just resolved, so this cannot miss
    defer desc.release(d)

    gfx.grid_clear(&p.grid, th[.Fg], gfx.opaque(th[.Bg]))

    // What is DRAWN is the view pipeline's document when a stage built one (VIEWS.md §5), and
    // `dv` is the map back to the one being edited. Nil for everything nobody derived.
    b := p.body
    t, dv := views_text(a, s.doc, &snap.text)
    // The link the pointer is in goes on LAST, so the one a click would take reads differently
    // from the rest of them (routing.odin).
    styles := styles_over(doc_styles(a, s.doc, d, t, dv, s.view.top, b.h),
                          doc_link_over(a, p, d, s.view, marked))
    // Borrowed from the document: the drawn text is a snapshot and the cursors are live, but
    // both are read after the drain (docs_settle), so they name the same generation.
    carets: []txt.Cursor
    if doc := store.store_doc(&a.docs, s.doc); doc != nil {
        carets = doc.cursors[:]
    }
    view.draw(&p.grid, th, t, d, s.view, b.x, b.y, b.w, b.h,
              styles, marked, dv, views_over(a, s.doc), a.config.select, carets, token_pal(a),
              &a.painter.atlas)
    if p.hover.on {
        // A columns document draws its FIELDS and not its bytes, so no style run reaches it —
        // the mark is the only way to underline a field there.
        view.underline(&p.grid, t, d, s.view, b.x, b.y, b.w, b.h,
                       p.hover.line, p.hover.lo, p.hover.hi, dv)
    }
}

// The focused caret's cell in framebuffer pixels — the same origin math surface_paint draws
// with, so what the platform IME docks to is where the caret is marked (IME.md §8).
caret_px :: proc(a: ^App, win_w, win_h: i32) -> (x, y: int, ok: bool) {
    ox, oy := gfx.painter_origin(&a.painter, win_w, win_h, a.ground.cols, a.ground.rows)
    cw, ch := gfx.painter_cell(&a.painter)
    if cl_active(a) {
        cx, cy, on := doc_caret_cell(a, a.cl.doc, a.cl.view, a.bar.x, a.bar.y, a.bar.w, 1)
        return ox + cx * cw, oy + cy * ch, on
    }
    p := panel_focused(a)
    s := panel_slot(a, p)
    if s == nil {
        return 0, 0, false
    }
    b := p.body
    cx, cy, on := doc_caret_cell(a, s.doc, s.view, b.x, b.y, b.w, b.h)
    if !on {
        return 0, 0, false
    }
    it := strip.span(a.strip, panel_spans(a), a.focus)
    return ox + int(it.x) + cx * cw, oy + int(a.frame.strip.y) + cy * ch, true
}

@(private = "file")
doc_caret_cell :: proc(a: ^App, id: store.Id, v: view.View,
                       x, y, w, h: int) -> (cx, cy: int, ok: bool) {
    snap := store.store_snapshot(&a.docs, id)
    if snap == nil {
        return 0, 0, false
    }
    defer txt.snapshot_release(snap)
    doc := store.store_doc(&a.docs, id)
    if doc == nil {
        return 0, 0, false
    }
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    t, dv := views_text(a, id, &snap.text)
    return view.caret_cell(t, d, v, x, y, w, h, doc.cursors[doc.primary].head, dv)
}

// The frame, on the GPU: every panel, then the frame in what they left. A panel's origin is the
// ground's corner plus what the strip says, which is pixels and not cells — that is the whole of
// what a gap, a half width and a camera cost here (§7).
//
// §6's order, and the DOCUMENTS GO FIRST (§15 stage 6): `gl_clear` has already laid the flat
// ground under the window, so a box is a gradient over the pixels nothing claimed — the gaps,
// the two rows, a ring around each panel and a dropdown across the lot.
surface_paint :: proc(a: ^App, win_w, win_h: i32) {
    p := &a.painter
    ox, oy := gfx.painter_origin(p, win_w, win_h, a.ground.cols, a.ground.rows)
    cw, ch := gfx.painter_cell(p)
    ss := panel_spans(a)
    top := oy + int(a.frame.strip.y) // where the frame's solve put the strip (frame.odin)
    for &pn, i in a.panels {
        it := strip.span(a.strip, ss, i)
        x := f32(ox) + it.x
        // The clip is the window's share of the panel, not the panel: one scrolled off the left
        // edge draws at a negative origin, and GL takes no negative box.
        lo, hi := max(x, 0), min(x + it.w, f32(win_w))
        if hi <= lo {
            continue
        }
        gfx.painter_draw(p, &pn.grid, win_w, win_h, {x, f32(top)},
                         {lo, f32(top), hi - lo, f32(pn.grid.rows * ch)})
    }
    // The pass brackets its own blend, because a box's colour is premultiplied.
    gfx.mesher_begin(&a.mesher, win_w, win_h)
    frame_paint(a, ox, oy, ss)
    gfx.mesher_end(&a.mesher)
    // The whole grid, over the boxes: every cell off the bar's row says NOTHING, and what draws
    // there is the frame under it (§13.3).
    gfx.painter_draw(p, &a.ground, win_w, win_h, {f32(ox), f32(oy)},
                     frame_px({0, 0, a.ground.cols, a.ground.rows}, {ox, oy}, {cw, ch}))
    menubar_paint(a, win_w, win_h) // last, over the boxes the frame drew for its grids
}

package main

import "../desc"
import "../gfx"
import "../store"
import "../strip"
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

// The surface the panels sit on, and the window's own margins with it: one answer, so a gap and
// the edge past the strip cannot end up two colours.
chrome_bg :: proc(a: ^App) -> [3]f32 {
    return gfx.theme_behind(a.theme, a.config.behind)
}

// The chrome is the whole fit; the strip gets everything above the bar. The cell size comes in
// because the strip is pixels and the grids are cells (§7); a caller with no painter leaves a
// cell one pixel, and its strip arithmetic then reads in columns.
surface_fit :: proc(a: ^App, cols, rows: int, cell := [2]int{1, 1}) {
    a.cell = cell
    gfx.grid_resize(&a.chrome, cols, rows)
    panels_fit(a, cols, rows)
}

surface_draw :: proc(a: ^App) {
    ch, th := &a.chrome, a.theme
    row := max(ch.rows - 1, 0)
    a.bar = {len(CL_PROMPT), row, max(ch.cols - len(CL_PROMPT), 0), 1}

    // The chrome is what a gap shows through, so it is darker than a panel: the strip then
    // reads as documents sitting ON something rather than as holes cut in one surface.
    behind := chrome_bg(a)
    gfx.grid_clear(ch, th[.Fg], behind)
    // The bar is the frame's row (§11), over whatever is below it — the kernel screen included.
    // While the command line is open it IS the bar: a state the user cannot see is the thing
    // §1 exists to kill, and the line is its own label.
    // The bar's row is the same dark line either way, so where the kernel talks is one place
    // that does not change colour when you open it. Only what is written on it changes: the
    // resting line is `Dim` and the command line is a document.
    defer if cl_active(a) {
        cl_draw(a, ch, th)
    } else {
        bar := bar_theme(th)
        bar_fill(ch, bar, row)
        gfx.grid_write(ch, 0, row, bar_text(a), bar[.Dim], bar[.Bg])
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

    gfx.grid_clear(&p.grid, th[.Fg], th[.Bg])

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
              styles, marked, dv, views_over(a, s.doc), a.config.select, carets, token_pal(a))
    if p.hover.on {
        // A columns document draws its FIELDS and not its bytes, so no style run reaches it —
        // the mark is the only way to underline a field there.
        view.underline(&p.grid, t, d, s.view, b.x, b.y, b.w, b.h,
                       p.hover.line, p.hover.lo, p.hover.hi, dv)
    }
}

// The frame, on the GPU: the chrome, then every panel over it. A panel's origin is the chrome's
// corner plus what the strip says, which is pixels and not cells — that is the whole of what a
// gap, a half width and a camera cost here (§7).
surface_paint :: proc(a: ^App, win_w, win_h: i32) {
    p := &a.painter
    ox, oy := gfx.painter_origin(p, win_w, win_h, a.chrome.cols, a.chrome.rows)
    _, ch := gfx.painter_cell(p)
    gfx.painter_draw(p, &a.chrome, win_w, win_h, {f32(ox), f32(oy)}, {0, 0, win_w, win_h})
    top := oy + menu_rows(a) * ch // the row a constant menubar keeps (MENU.md §4)
    ws := panel_widths(a)
    for &pn, i in a.panels {
        it := strip.span(a.strip, ws, i)
        x := f32(ox) + it.x
        // The clip is the window's share of the panel, not the panel: one scrolled off the left
        // edge draws at a negative origin, and GL takes no negative box.
        lo, hi := max(i32(x), 0), min(i32(x + it.w), win_w)
        if hi <= lo {
            continue
        }
        gfx.painter_draw(p, &pn.grid, win_w, win_h, {x, f32(top)},
                         {lo, i32(top), hi - lo, i32(pn.grid.rows * ch)})
    }
    menubar_paint(a, win_w, win_h) // last, over the panels (MENU.md §4)
}

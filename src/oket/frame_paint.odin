package main

import "core:c"
import "../gfx"
import "../strip"

// What the frame LOOKS like (CHROME.md §6). frame.odin says where every box is and gfx/box.odin
// says how one is drawn; this is the table between them. It reads the THEME rather than a baked
// palette, so `:theme` moves the frame with the documents.
//
// WHAT IS VISIBLE TODAY IS THE STRIP'S GROUND: the gap between two panels, and the space past
// the last one. The bar's row and the menubar's are cell grids painted OVER this pass, and a
// cell background that says `gfx.NOTHING` lets this pass through — so a box drawn under either
// of them is a box that stays on screen (§13.3).

// Clearlooks' whole trick: a surface is lighter along its top edge than along its bottom. Steps
// in percent, and small — the ladder has to read on a cream theme as well as a dark one.
@(private = "file")
GROUND_LIFT :: 6 // the strip's ground, top against bottom
@(private = "file")
GROOVE_DARK :: 45 // the dark half of a SUNKEN edge, which is the dark one on top
@(private = "file")
GROOVE_LIFT :: 14 // and the light half under it
@(private = "file")
ROW_LIFT :: 8 // the bar's row and the menubar's, lit along the top the way every surface is

// How far proud of a panel its groove is drawn, in pixels. The panel's own grid is painted after
// this pass and is opaque, so it covers the inside and leaves the ring — which is why a slot
// carries no padding. THE FRAME LIVES IN THE GAP, and a strip with no gap has nowhere to put one.
@(private = "file")
PROUD :: f32(1)

// The frame, as quads. One upload and one draw for all of it (mesher_paint): the whole frame is
// a few hundred vertices, so there is no handle per box for anyone to release.
frame_paint :: proc(a: ^App, ox, oy: int, slots: []strip.Span) {
    verts := make([dynamic]gfx.Chrome_Vertex, 0, 64, context.temp_allocator)
    idx := make([dynamic]c.int, 0, 192, context.temp_allocator)

    st := a.frame.strip
    x0, y0 := f32(ox), f32(oy)
    gfx.box_mesh(&verts, &idx, {x0 + st.x, y0 + st.y, st.w, st.h}, ground_look(a))
    // The two rows the solve keeps. A hidden menubar is a rect of no height, and `box_mesh`
    // draws nothing for one, so neither row is a branch here.
    at := [2]int{ox, oy}
    gfx.box_mesh(&verts, &idx, gfx.box_of(frame_px(a.frame.menu, at, a.cell)), menu_look(a))
    gfx.box_mesh(&verts, &idx, gfx.box_of(frame_px(a.frame.bar, at, a.cell)), bar_look(a))

    // The camera is applied HERE, which is the whole reason a hand-rolled pass can frame a panel
    // at all: a stylesheet answers the resting strip, and a scrolled one would draw its frames
    // where the panels are not (§2.1).
    for _, i in a.panels {
        s := strip.span(a.strip, slots, i)
        gfx.box_mesh(&verts, &idx,
                     {x0 + s.x - PROUD, y0 + st.y - PROUD, s.w + 2 * PROUD, st.h + 2 * PROUD},
                     groove_look(a))
    }

    gfx.mesher_paint(&a.mesher, verts[:], idx[:])
}

// The menubar's row, off the theme THE BAR ITSELF is drawn in: an inverted menubar lifts toward
// its own ink and not the document's (menubar_screen.odin).
@(private = "file")
menu_look :: proc(a: ^App) -> gfx.Look {
    th := menu_theme(a)
    return {fill = {gfx.opaque(gfx.lift(th, th[.Bg], ROW_LIFT)), gfx.opaque(th[.Bg])}}
}

// The bar's row, off the shade `bar_theme` writes its cells in — one number, so the box and the
// command line that covers it cannot end up two darknesses (cl.odin).
@(private = "file")
bar_look :: proc(a: ^App) -> gfx.Look {
    base := gfx.theme_behind(a.theme, BAR_BEHIND)
    return {fill = {gfx.opaque(gfx.lift(a.theme, base, ROW_LIFT)), gfx.opaque(base)}}
}

// The surface the panels sit ON, one step lighter at the top than at the bottom.
@(private = "file")
ground_look :: proc(a: ^App) -> gfx.Look {
    base := ground_bg(a)
    return {fill = {gfx.opaque(gfx.lift(a.theme, base, GROUND_LIFT)), gfx.opaque(base)}}
}

// A SUNKEN edge, which is a raised one upside down: dark along the top, light along the bottom.
// That is what makes a panel read as let INTO the strip rather than sitting on it. Its fill is
// the document's own ground and is covered by the panel's grid the moment there is one.
@(private = "file")
groove_look :: proc(a: ^App) -> gfx.Look {
    base := ground_bg(a)
    return {
        edge   = {gfx.opaque(gfx.shade(base, GROOVE_DARK)),
                  gfx.opaque(gfx.lift(a.theme, base, GROOVE_LIFT))},
        fill   = {gfx.opaque(a.theme[.Bg]), gfx.opaque(a.theme[.Bg])},
        border = 1,
        radius = 2,
    }
}

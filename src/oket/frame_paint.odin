package main

import "core:c"
import "../gfx"
import "../menu"
import "../strip"

// What the frame LOOKS like (CHROME.md §6). frame.odin says where every box is and gfx/box.odin
// says how one is drawn; this is the table between them. It reads the THEME rather than a baked
// palette, so `:theme` moves the frame with the documents.
//
// THE PASS RUNS AFTER THE PANELS (§15 stage 6), so every box here is drawn in the space the
// documents left: the gaps between them, a ring proud of each one, the two rows the solve keeps
// and a dropdown hanging over the lot. `gl_clear` already laid the flat ground down under all of
// it, so what this pass owes is the GRADIENT and never the background.

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
@(private = "file")
DROP_LIFT :: 22 // a dropdown's edge, which is RAISED: light on top, dark under it
@(private = "file")
DROP_DARK :: 30
// What one step is worth on a LIGHT surface. The eye reads a difference against what is already
// under it, so the six points that read on a near-black ground are nothing on cream.
@(private = "file")
LIGHT_STEP :: 2
// A popup's shadow: how far it falls, in pixels, and how much of the light it takes.
@(private = "file")
ROW_EDGE :: 22 // the hairline around one compartment of a list, off that list's own surface
@(private = "file")
SHADOW :: f32(3)
@(private = "file")
SHADOW_ALPHA :: f32(0.3)

// How far proud of a panel its groove is drawn, in pixels. The panel's grid is already down, so
// the ring is all there is to draw: `groove_look` says NOTHING inside it and covers no cell of
// the document. THE FRAME LIVES IN THE GAP, and a strip with no gap has nowhere to put one.
@(private = "file")
PROUD :: f32(1)

// The frame, as quads. One upload and one draw for all of it (mesher_paint): the whole frame is
// a few hundred vertices, so there is no handle per box for anyone to release.
frame_paint :: proc(a: ^App, slots: []strip.Span) {
    verts := make([dynamic]gfx.Chrome_Vertex, 0, 64, context.temp_allocator)
    idx := make([dynamic]c.int, 0, 192, context.temp_allocator)

    for gap in ground_gaps(a, slots) {
        gfx.box_mesh(&verts, &idx, gap, ground_look(a))
    }
    gfx.box_mesh(&verts, &idx, a.frame.bar, bar_look(a))

    // The camera is applied HERE, which is the whole reason a hand-rolled pass can frame a panel
    // at all: a stylesheet answers the resting strip, and a scrolled one would draw its frames
    // where the panels are not (§2.1).
    st := a.frame.strip
    for _, i in a.panels {
        s := strip.span(a.strip, slots, i)
        gfx.box_mesh(&verts, &idx,
                       {s.x - PROUD, st.y - PROUD, s.w + 2 * PROUD, st.h + 2 * PROUD},
                     groove_look(a))
    }

    // The menubar's boxes, at the rects `src/menu` put its grids at — the one geometry outside
    // the solve, because a popup is anchored and `lay` tiles (§13.4). A reserved row and a
    // floating one are the same box now that nothing is drawn after them, so neither the bar
    // nor a dropdown paints a ground of its own.
    for &l, part in a.menu {
        if !l.on {
            continue
        }
        grid := gfx.Rect{l.at.x, l.at.y,
                        f32(l.grid.cols * a.cell.x), f32(l.grid.rows * a.cell.y)}
        if part == .Bar {
            gfx.box_mesh(&verts, &idx, grid, menu_look(a))
            continue
        }
        box := menu.popup_rect({at = {grid.x, grid.y}, w = l.grid.cols, h = l.grid.rows},
                               {f32(a.cell.x), f32(a.cell.y)})
        // Draw the shadow before the popup.
        gfx.box_mesh(&verts, &idx, {box.x + SHADOW, box.y + SHADOW, box.w, box.h}, shadow_look())
        gfx.box_mesh(&verts, &idx, box, drop_look(a))
        // Draw each row as its own compartment.
        for r in 0 ..< l.grid.rows {
            gfx.box_mesh(&verts, &idx, row_px(grid, r, a.cell), row_look(a, r == l.lit))
        }
    }

    gfx.mesher_paint(&a.mesher, verts[:], idx[:])
}

// Inset row backgrounds from the popup bevel.
@(private = "file")
row_px :: proc(box: gfx.Rect, row: int, cell: [2]int) -> gfx.Rect {
    pad := f32(cell.x) / 2
    return {box.x + pad, box.y + f32(row * cell.y), box.w - 2 * pad, f32(cell.y)}
}

// The strip's ground is the GAPS: the space before the first panel, between two of them, and
// past the last. One rect spanning the strip would cover the documents, which is what the
// reorder cost it. Each keeps the strip's own `y` and `h`, so `box_mesh` lerps one gradient down
// all of them and no seam shows between one gap and the next.
ground_gaps :: proc(a: ^App, slots: []strip.Span,
                    allocator := context.temp_allocator) -> []gfx.Rect {
    st := a.frame.strip
    out := make([dynamic]gfx.Rect, 0, len(a.panels) + 1, allocator)
    left := st.x
    for _, i in a.panels {
        s := strip.span(a.strip, slots, i)
        append(&out, gfx.Rect{left, st.y, s.x - left, st.h})
        // A panel scrolled off the left edge starts behind the last one's end, and a gap that
        // walked backwards would be drawn OVER the document beside it.
        left = max(left, s.x + s.w)
    }
    append(&out, gfx.Rect{left, st.y, st.x + st.w - left, st.h})
    return out[:]
}

// A SURFACE'S TWO ENDS, light first. Which end moves is which way round the theme is: `lift`
// goes toward the theme's INK, which on a light ground is DOWN — so a light surface shades its
// BOTTOM where a dark one lifts its TOP. Lifting a cream bar toward its ink darkens the wrong
// edge, which is what an inverted menubar was doing (§8).
@(private = "file")
gradient :: proc(th: gfx.Theme, base: [3]f32, step: int) -> [2]gfx.Rgba {
    if gfx.theme_dark(th) {
        return {gfx.opaque(gfx.lift(th, base, step)), gfx.opaque(base)}
    }
    return {gfx.opaque(base), gfx.opaque(gfx.shade(base, step * LIGHT_STEP))}
}

// The menubar's row, off the theme THE BAR ITSELF is drawn in: an inverted menubar is a light
// surface and reads by its own ends, not the document's (menubar_screen.odin).
@(private = "file")
menu_look :: proc(a: ^App) -> gfx.Look {
    th := menu_theme(a)
    return {fill = gradient(th, th[.Bg], ROW_LIFT)}
}

// A dropdown and its popout: the bar's own surface, RAISED off whatever it hangs over. It is the
// last piece of chrome that was drawn out of the atlas — the border is the box's bevel now and
// not a `┌─┐` in cells (menu.odin, draw_list).
@(private = "file")
drop_look :: proc(a: ^App) -> gfx.Look {
    th := menu_theme(a)
    return {
        edge   = {gfx.opaque(gfx.lift(th, th[.Bg], DROP_LIFT)),
                  gfx.opaque(gfx.shade(th[.Bg], DROP_DARK))},
        fill   = gradient(th, th[.Bg], ROW_LIFT),
        border = 1,
        radius = 2,
    }
}

// One compartment of a list. The LIT one differs in its fill and in nothing else, so the row the
// keys are on is the same shape as every other row rather than a mark laid over one — and
// `draw_row` writes its ink the other way round and paints nothing behind it.
@(private = "file")
row_look :: proc(a: ^App, lit: bool) -> gfx.Look {
    th := menu_theme(a)
    base := lit ? th[.Accent] : th[.Bg]
    return {
        fill   = gradient(th, base, ROW_LIFT),
        edge   = gradient(th, th[.Bg], ROW_EDGE),
        border = 1,
        radius = 2,
    }
}

// What a popup drops on what is under it. Black at a low alpha rather than a shade of anything:
// a shadow is not the theme's colour, it is less light reaching what is below.
@(private = "file")
shadow_look :: proc() -> gfx.Look {
    return {fill = {{0, 0, 0, SHADOW_ALPHA}, {0, 0, 0, SHADOW_ALPHA}}, radius = 3}
}

// The bar's row, off the shade `bar_theme` writes its cells in — one number, so the box and the
// command line that covers it cannot end up two darknesses (cl.odin).
@(private = "file")
bar_look :: proc(a: ^App) -> gfx.Look {
    base := gfx.theme_behind(a.theme, BAR_BEHIND)
    return {fill = gradient(a.theme, base, ROW_LIFT)}
}

// The surface the panels sit ON, one step lighter at the top than at the bottom.
@(private = "file")
ground_look :: proc(a: ^App) -> gfx.Look {
    base := ground_bg(a)
    return {fill = gradient(a.theme, base, GROUND_LIFT)}
}

// A SUNKEN edge, which is a raised one upside down: dark along the top, light along the bottom.
// That is what makes a panel read as let INTO the strip rather than sitting on it. A RING and
// nothing else: the fill says NOTHING, so the panel drawn before this pass stands where it is.
@(private = "file")
groove_look :: proc(a: ^App) -> gfx.Look {
    base := ground_bg(a)
    return {
        edge   = {gfx.opaque(gfx.shade(base, GROOVE_DARK)),
                  gfx.opaque(gfx.lift(a.theme, base, GROOVE_LIFT))},
        border = 1,
        radius = 2,
    }
}

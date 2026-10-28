package main

import "../gfx"
import "../menu"
import "../strip"

// The frame, flat (CHROME.md §6), drawn after the panels into what they left. `gl_clear`
// already laid the ground, so the gaps cost nothing here.

@(private = "file")
RING_DARK :: 45 // the splitter ring, off the ground
@(private = "file")
DROP_DARK :: 30 // a dropdown's bottom and right edge, off its own ground

frame_paint :: proc(a: ^App, slots: []strip.Span, win_h: i32) {
    gfx.fill(a.frame.bar, gfx.theme_behind(a.theme, BAR_BEHIND), win_h)

    // A 1px ring in the gap round each panel, camera applied.
    st := a.frame.strip
    ring := gfx.shade(ground_bg(a), RING_DARK)
    for _, i in a.panels {
        s := strip.span(a.strip, slots, i)
        rim({s.x - 1, st.y - 1, s.w + 2, st.h + 2}, ring, ring, win_h)
    }

    // A popup is one box: its ground, a rule between rows, a raised rim. The lit row is the
    // grid's own cell bg (menu.odin, draw_row).
    th := menu_theme(a)
    for &l, part in a.menu.layers {
        if !l.on {
            continue
        }
        grid := gfx.Rect{l.at.x, l.at.y,
                        f32(l.grid.cols * a.cell.x), f32(l.grid.rows * a.cell.y)}
        if part == .Bar {
            gfx.fill(grid, th[.Bg], win_h)
            continue
        }
        box := menu.popup_rect({at = {grid.x, grid.y}, w = l.grid.cols, h = l.grid.rows},
                               {f32(a.cell.x), f32(a.cell.y)})
        gfx.fill(box, th[.Bg], win_h)
        for r in 1 ..< l.grid.rows {
            gfx.fill({box.x, grid.y + f32(r * a.cell.y), box.w, 1}, th[.Dim], win_h)
        }
        rim(box, th[.Dim], gfx.shade(th[.Bg], DROP_DARK), win_h)
    }
}

// A 1px border just inside `r`: `lit` on the top and left, `dark` on the bottom and right.
@(private = "file")
rim :: proc(r: gfx.Rect, lit, dark: [3]f32, win_h: i32) {
    gfx.fill({r.x, r.y, r.w, 1}, lit, win_h)
    gfx.fill({r.x, r.y, 1, r.h}, lit, win_h)
    gfx.fill({r.x, r.y + r.h - 1, r.w, 1}, dark, win_h)
    gfx.fill({r.x + r.w - 1, r.y, 1, r.h}, dark, win_h)
}

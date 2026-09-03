package main

import "../gfx"
import "../store"

// The strip (PANELS.md §2, §5). A panel is a Spot, a rect and a grid, and nothing more: what
// differs between panels — the document and the viewport over it — is already per-slot, and what
// an instance would duplicate stays single. So there is no document state here. `at` points into
// the ring and the rest is where the panel was last drawn.
//
// The verbs that make the strip longer than one are stage 3.
//
// A ^Panel points into a [dynamic], so nothing holds one across a call that may open a panel.

Panel :: struct {
    at:    Spot, // the lane, and the slot inside it, this panel shows
    prev:  Spot, // alt+`: the most recent spot IN THIS PANEL
    grid:  gfx.Grid,
    // Where the document was drawn, in the panel's OWN cells. A click is placed against it, so
    // the hit test reads the layout the eye saw rather than recomputing one.
    body:  Rect,
    hover: Hover,
}

// The field under the pointer that a bound click would act on (§8). Underlined, and no surface
// writes a line of it: the bind table is asked what a click there would do. Per panel, because
// the pointer is over one of them.
Hover :: struct {
    line, lo, hi: int,
    on:           bool,
}

// The strip is never empty. Every reader goes through here rather than through a start of its
// own, because the first document can reach the ring before the first fit does (main.odin).
panels_ready :: proc(a: ^App) {
    if len(a.panels) == 0 {
        append(&a.panels, Panel{})
    }
}

// The panel the keys, the ring and the command line act on. Never nil: a frame always has one to
// draw into, even at a window height that leaves it no rows.
panel_focused :: proc(a: ^App) -> ^Panel {
    panels_ready(a)
    return &a.panels[clamp(a.focus, 0, len(a.panels) - 1)]
}

// Panel `i` of the strip, nil out of range: lane_get's shape, for the same callers.
panel_get :: proc(a: ^App, i: int) -> ^Panel {
    return i >= 0 && i < len(a.panels) ? &a.panels[i] : nil
}

// The slot a panel is showing, nil while it stands on a gap.
panel_slot :: proc(a: ^App, p: ^Panel) -> ^Slot {
    return lane_get(&a.ring, p.at.lane, p.at.slot)
}

// A grid of no rows is legal and draws nothing, which is what keeps the small end from being a
// special case.
panels_fit :: proc(a: ^App, cols, rows: int) {
    panels_ready(a)
    for &p in a.panels {
        gfx.grid_resize(&p.grid, cols, max(rows - 1, 0))
    }
}

panels_destroy :: proc(a: ^App) {
    for &p in a.panels {
        gfx.grid_destroy(&p.grid)
    }
    delete(a.panels)
    a.panels = nil
}

// A panel's rectangle on the SCREEN, in chrome cells. The strip is one long, so a panel starts
// at the screen's own corner; giving a panel an origin of its own is stage 3.
panel_screen :: proc(a: ^App, i: int) -> Rect {
    g := &a.panels[i].grid
    return {0, 0, g.cols, g.rows}
}

// Which panel a screen cell lands in, and where in that panel's own cells (PANELS.md §7). A
// column number means nothing until you know whose grid it counts from, so the panel is answered
// first. -1 is the chrome, which today is the bar's row.
panel_hit :: proc(a: ^App, sx, sy: int) -> (panel, x, y: int) {
    for _, i in a.panels {
        r := panel_screen(a, i)
        if sx >= r.x && sx < r.x + r.w && sy >= r.y && sy < r.y + r.h {
            return i, sx - r.x, sy - r.y
        }
    }
    return -1, sx, sy
}

// The rectangle a document was last drawn in. A live slot the strip is not showing still has a
// viewport the kernel moves (§11) and still needs a page height, and the focused panel's is the
// only honest answer for a document you cannot see.
doc_rect :: proc(a: ^App, id: store.Id) -> Rect {
    for &p in a.panels {
        if s := panel_slot(a, &p); s != nil && s.doc == id {
            return p.body
        }
    }
    return panel_focused(a).body
}

// --- hover (§8) ---

hover_on :: proc(a: ^App) -> bool {
    for &p in a.panels {
        if p.hover.on {
            return true
        }
    }
    return false
}

hover_clear :: proc(a: ^App) {
    for &p in a.panels {
        p.hover = {}
    }
}

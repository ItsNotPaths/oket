package main

import "core:math"
import "../gfx"
import "../store"
import "../strip"

// The strip (PANELS.md §2, §5). A panel is a Spot, a rect and a grid, and nothing more: what
// differs between panels — the document and the viewport over it — is already per-slot, and what
// an instance would duplicate stays single. So there is no document state here. `at` points into
// the ring and the rest is where the panel was last drawn.
//
// Where a panel LANDS is src/strip's, which knows none of this (§9). The kernel says which
// widths are on the strip and which one has focus; the strip answers in pixels.
//
// A ^Panel points into a [dynamic], so nothing holds one across a call that may open a panel.

Panel :: struct {
    at:    Spot, // the lane, and the slot inside it, this panel shows
    prev:  Spot, // alt+`: the most recent spot IN THIS PANEL
    size:  strip.Width, // full or half; `panel.size` toggles it
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

// The panel standing on a spot, nil for one no panel is showing. A live slot is in at most one
// panel (§2), and this is what ring_move asks to keep that true.
panel_showing :: proc(a: ^App, at: Spot) -> ^Panel {
    for &p in a.panels {
        if p.at == at {
            return &p
        }
    }
    return nil
}

// --- the verbs (§5) ---

// A panel to the right of the focused one, and the focus goes with it: `panel.open`.
panel_open :: proc(a: ^App) {
    panel_focus(a, panel_make(a, a.focus + 1))
}

// A panel at index `i`, standing on nothing until something opens there. It takes the focused
// panel's LANE, so `alt+N` in the new panel addresses the numbers you were just looking at and
// lands a fresh document on an empty one. The focus stays on the panel that had it, whichever
// side of the new one that leaves it.
panel_make :: proc(a: ^App, i: int) -> int {
    p := panel_focused(a)
    made := Panel {
        at   = {p.at.lane, 0},
        size = p.size,
    }
    at := clamp(i, 0, len(a.panels))
    inject_at(&a.panels, at, made)
    if at <= a.focus {
        a.focus += 1
    }
    panels_relayout(a)
    return at
}

// The panel goes, the documents stay: closing a panel is not closing what was in it, and the
// ring renumbers nothing (§3). The strip is never empty, so the last one refuses.
panel_close :: proc(a: ^App) -> bool {
    if len(a.panels) < 2 {
        message_set(a, "panel.close: the strip is one panel long")
        return false
    }
    gfx.grid_destroy(&a.panels[a.focus].grid)
    ordered_remove(&a.panels, a.focus)
    a.focus = clamp(a.focus, 0, len(a.panels) - 1)
    panels_relayout(a)
    return true
}

// `panel.next` and `panel.prev`. Clamped, not wrapped: a strip has two ends and walking off one
// into the other is a carousel.
panel_step :: proc(a: ^App, by: int) {
    panels_ready(a)
    panel_focus(a, clamp(a.focus + by, 0, len(a.panels) - 1))
}

// The full/half toggle, which is the whole sizing model (§5).
panel_resize :: proc(a: ^App) {
    p := panel_focused(a)
    p.size = p.size == .Full ? .Half : .Full
    panels_relayout(a)
}

// --- the layout ---

// The strip's input: one width per panel, in strip order. Temp-allocated, because the widths
// live on the panels and the strip holds no copy to go stale.
panel_widths :: proc(a: ^App) -> []strip.Width {
    panels_ready(a)
    w := make([]strip.Width, len(a.panels), context.temp_allocator)
    for p, i in a.panels {
        w[i] = p.size
    }
    return w
}

// A grid of no rows is legal and draws nothing, which is what keeps the small end from being a
// special case.
panels_fit :: proc(a: ^App, cols, rows: int) {
    a.strip.view = f32(cols * a.cell.x)
    a.strip.gap = f32(a.config.gap)
    ws := panel_widths(a)
    a.strip.camera = strip.look_at(a.strip, ws, a.focus) // the camera follows focus (§5)
    for &p, i in a.panels {
        gfx.grid_resize(&p.grid, panel_cols(strip.span(a.strip, ws, i).w, a.cell.x),
                        max(rows - 1, 0))
    }
}

// The strip, laid out again from what the last fit measured. Every verb that changes the strip
// ends here, so a panel is the right size before the next draw rather than after it.
panels_relayout :: proc(a: ^App) {
    panels_fit(a, a.chrome.cols, a.chrome.rows)
}

// The columns a panel's pixel width holds. Its grid rides the panel's OWN origin, so only the
// right edge can cut a glyph and there is no second column to add for the left one. Half a glyph
// there is the affordance that says the line continues, and the clip is what takes it (§7).
panel_cols :: proc(w: f32, cell_w: int) -> int {
    return cell_w > 0 ? int(math.ceil(w / f32(cell_w))) : 0
}

panels_destroy :: proc(a: ^App) {
    for &p in a.panels {
        gfx.grid_destroy(&p.grid)
    }
    delete(a.panels)
    a.panels = nil
}

// Which panel a screen PIXEL lands in, and where in that panel's own cells (PANELS.md §7). A
// column number means nothing until you know whose grid it counts from, so the panel is answered
// first. -1 is the chrome: the bar's row, a gap, or the space past the last panel.
panel_hit :: proc(a: ^App, px, py: int) -> (panel, x, y: int) {
    row := floor_div(py, a.cell.y)
    ws := panel_widths(a)
    if i := strip.hit(a.strip, ws, f32(px)); i >= 0 && row < a.panels[i].grid.rows {
        return i, floor_div(px - int(strip.span(a.strip, ws, i).x), a.cell.x), row
    }
    return -1, floor_div(px, a.cell.x), row
}

// Truncation toward zero would fold the column left of a grid onto column 0.
floor_div :: proc(n, d: int) -> int {
    if d <= 0 {
        return 0
    }
    return n >= 0 ? n / d : -((-n + d - 1) / d)
}

// Click to focus (§7): the cell that comes back counts from the panel it landed in, so the keys
// have to be aimed there before anything is placed against it. The camera follows focus (§5),
// so a panel aimed at from the command line scrolls into view rather than acting off screen.
panel_focus :: proc(a: ^App, i: int) {
    if panel_get(a, i) != nil {
        a.focus = i
        panels_relayout(a)
    }
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

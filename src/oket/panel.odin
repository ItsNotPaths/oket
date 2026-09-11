package main

import "../gfx"
import "../input"
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
    size:  int, // its share of the view, in hundredths of a percent; `:width` sets it
    // Where it is drawn NOW, and where the frame's solve says it RESTS (frame.odin). A panel
    // that is resizing is between the two, and `panels_step` walks it there on the clock (§7).
    now:   strip.Span,
    dest:  strip.Span,
    grid:  gfx.Grid,
    // Where the document was drawn, in the panel's OWN cells. A click is placed against it, so
    // the hit test reads the layout the eye saw rather than recomputing one.
    body:  Cells,
    hover: Hover,
}

// The field under the pointer that a bound click would act on (§8). Underlined, and no surface
// writes a line of it: the bind table is asked what a click there would do. Per panel, because
// the pointer is over one of them.
Hover :: struct {
    line, lo, hi: int,
    on:           bool,
}

// A share of the view, in HUNDREDTHS OF A PERCENT, so one panel at the full share is a strip of
// length one rather than a special case. Not whole percents: a third is 33.33, and three panels
// at a whole 33 leave a hundredth of the view empty behind them, which is a sliver you can see.
// `:width` still takes percents — this is only the unit they land in.
//
// WIDTH_MIN is what keeps a mistyped row from leaving a panel nobody can find.
WIDTH_FULL :: 10_000
WIDTH_MIN :: 100 // one percent

// The fractions a share is snapped to, as a denominator: halves through sixths, which is every
// split a strip is worth having. Sevenths and finer are past the point where a panel holds a
// line of code, and they would sit close enough together to swallow a number somebody meant.
WIDTH_PARTS :: 6

// How near a typed percent has to be to an exact fraction to become it. 3.5 percent, because
// `:width 30` means a third — the default row says 30 and three of them must fill the strip.
// Tighten this and 30 stays 30; the words `third` and `half` are exact either way.
WIDTH_SNAP :: 350

// The nearest exact fraction of the view, or the share as it stands when nothing is near. `m/n`
// and not just `1/n`, so two thirds is as reachable as one.
width_snap :: proc(share: int) -> int {
    best, gap := share, WIDTH_SNAP + 1
    for n in 1 ..= WIDTH_PARTS {
        for m in 1 ..= n {
            exact := WIDTH_FULL * m / n
            if d := abs(share - exact); d < gap {
                best, gap = exact, d
            }
        }
    }
    return best
}

// The strip is never empty. Every reader goes through here rather than through a start of its
// own, because the first document can reach the ring before the first fit does (main.odin).
panels_ready :: proc(a: ^App) {
    if len(a.panels) == 0 {
        append(&a.panels, Panel{size = WIDTH_FULL})
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

// The panel standing on a spot, -1 for one no panel is showing. A live slot is in at most one
// panel (§2), so this answers once — and it answers as an INDEX because an address names a
// panel by number and a pointer into a [dynamic] is not one (`@=`, target.odin).
panel_at_spot :: proc(a: ^App, at: Spot) -> int {
    for p, i in a.panels {
        if p.at == at {
            return i
        }
    }
    return -1
}

// The same walk, for the callers that want the panel itself. ring_move is the one that asks, to
// keep the rule above true.
panel_showing :: proc(a: ^App, at: Spot) -> ^Panel {
    i := panel_at_spot(a, at)
    return i < 0 ? nil : &a.panels[i]
}

// --- the verbs (§5) ---

// A panel to the right of the one the keys are AIMED at, and the aim goes with it: `panel.open`,
// and `:np` from the command line. While the picker is armed that is its target, so the same
// verb makes somewhere to throw the file to and steers to it (§6).
panel_open :: proc(a: ^App) {
    panel_aim(a, panel_make(a, panel_marked(a) + 1))
    // It stands on the HOME PAGE and not on nothing. An empty panel is a floor with no answer
    // on it, and the page is what the kernel has to say when there is nothing there yet (§13).
    // Not while a picker is armed: that gesture makes somewhere to throw a file to, the throw
    // is one keystroke away, and the aim is a mark rather than the focus ring_add would move.
    if _, armed := a.pending.(input.Pending_Pick); !armed {
        ring_add(a, home_open(a))
    }
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

// `panel.move_left` and `panel.move_right`: the panel changes place, the documents do not. The
// aim goes with it, so the thing you were looking at is still the thing you are looking at.
// Clamped like the walk — a strip has two ends.
panel_shift :: proc(a: ^App, by: int) {
    i := panel_marked(a)
    j := clamp(i + by, 0, len(a.panels) - 1)
    if i == j {
        return
    }
    a.panels[i], a.panels[j] = a.panels[j], a.panels[i]
    panel_aim(a, j)
    panels_relayout(a) // the widths reordered, whatever the aim did with the focus
}

// `:width`, on the LIVE panel the line named — that it is live is target_panel's check, not
// this one's. The list is a CYCLE, so one percent is a set, two a toggle, and the sizing model
// is whatever the row says it is (§5).
panel_width :: proc(a: ^App, i: int, pcts: []int) {
    p := &a.panels[i]
    p.size = width_next(p.size, pcts)
    panels_relayout(a)
}

// The percent after the one the panel is at. A panel at a percent the list does not name takes
// the first, so a row you just edited lands on its own first entry rather than nowhere.
@(private = "file")
width_next :: proc(now: int, pcts: []int) -> int {
    for pct, i in pcts {
        if pct == now {
            return pcts[(i + 1) % len(pcts)]
        }
    }
    return pcts[0]
}

// --- the layout ---

// The strip's input: one slot per panel, in strip order, in PIXELS. Two of them, because a
// panel that is resizing is not yet where its percent says — this is what is DRAWN, and
// `panel_dests` is what it is moving to (§7). Temp-allocated, because the slots live on the
// panels and the strip holds no copy to go stale.
panel_spans :: proc(a: ^App) -> []strip.Span {
    panels_ready(a)
    it := make([]strip.Span, len(a.panels), context.temp_allocator)
    for p, i in a.panels {
        it[i] = p.now
    }
    return it
}

// Where every panel RESTS, as the frame's last solve answered it (frame.odin). The camera aims
// at this layout and not at the one in flight, so a resize and the scroll after it settle in one
// place.
panel_dests :: proc(a: ^App) -> []strip.Span {
    panels_ready(a)
    it := make([]strip.Span, len(a.panels), context.temp_allocator)
    for p, i in a.panels {
        it[i] = p.dest
    }
    return it
}

// A grid of no rows is legal and draws nothing, which is what keeps the small end from being a
// special case.
panels_fit :: proc(a: ^App) {
    a.strip.tau = f32(a.config.tau) / 1000 // the file is milliseconds; the clock is seconds
    // Every rect below comes out of here, and nothing below computes one (frame.odin, §2.1).
    frame_fit(a, a.win.x, a.win.y)
    // A WINDOW resize is not a panel resize: the view moved under every panel at once, and
    // animating that would be the window's own resize drawn twice. So they land, and so does
    // everything while tau is zero, which is what motion off means (§7).
    land := a.frame.strip.w != a.strip.view || a.strip.tau <= 0
    a.strip.view = a.frame.strip.w
    dest := panel_dests(a)
    // The camera follows the MARK and not the focus (§3, §5): the caret is what says where the
    // next thing lands, and a target you cannot see is a gesture steered blind. Unarmed the two
    // are the same panel, so this is the old rule with the picker's answer folded in.
    a.strip.aim = strip.look_at(a.strip, dest, panel_marked(a))
    if land {
        a.strip.camera = a.strip.aim
    }
    // The grid covers the strip; the text floors onto the pane's top-left (§11).
    tall := frame_cover(a.frame.strip.h, a.cell.y)
    for &p, i in a.panels {
        if land || p.now.w <= 0 {
            p.now = dest[i] // a panel with no width yet lands; nothing slides in from nothing
        }
        // THE DOCUMENT LAYS OUT AT THE WIDTH THE PANEL IS ARRIVING AT, ONCE (§7). So the body
        // is the destination and not what is on screen this frame, and the clip animates over
        // text that is already in its final layout — one reflow per resize, and one winsize.
        wide := frame_cover(dest[i].w, a.cell.x)
        p.body = {0, 0, frame_cols(dest[i].w, a.cell.x), a.frame.body.h}
        // While it moves the grid holds both ends of the motion, so it is allocated once per
        // resize rather than once per frame.
        gfx.grid_resize(&p.grid, p.now == dest[i] ? wide : max(wide, p.grid.cols), tall)
    }
}

// One step of the strip's motion, on the clock (§7). True while anything is still moving, which
// is what keeps the frame loop polling instead of waiting for a key that is not coming.
panels_step :: proc(a: ^App, dt: f32) -> bool {
    panels_ready(a)
    moving := false
    for &p in a.panels {
        // Both ends of the slot, because where a panel rests is a rect the solve answered and
        // no longer a width somebody accumulated (frame.odin).
        if p.now != p.dest {
            p.now = {
                strip.approach(p.now.x, p.dest.x, dt, a.strip.tau),
                strip.approach(p.now.w, p.dest.w, dt, a.strip.tau),
            }
            moving = true
        }
    }
    if a.strip.camera != a.strip.aim {
        a.strip.camera = strip.approach(a.strip.camera, a.strip.aim, dt, a.strip.tau)
        moving = true
    }
    if moving {
        panels_relayout(a)
    }
    return moving
}

// The strip, laid out again from what the last fit measured. Every verb that changes the strip
// ends here, so a panel is the right size before the next draw rather than after it.
panels_relayout :: proc(a: ^App) {
    panels_fit(a)
}

panels_destroy :: proc(a: ^App) {
    for &p in a.panels {
        gfx.grid_destroy(&p.grid)
    }
    delete(a.panels)
    a.panels = nil
}

// The menu's own lattice, which is nobody's panel: a click on it is worked by the menubar and
// the panel under it never hears about it (MENU.md §6).
PANEL_MENU :: -2

// Which panel a screen PIXEL lands in, and where in that panel's own cells (PANELS.md §7). A
// column number means nothing until you know whose grid it counts from, so the panel is answered
// first. -1 is the ground: the bar's row, a gap, or the space past the last panel.
panel_hit :: proc(a: ^App, px, py: int) -> (panel, x, y: int) {
    col, win := floor_div(px, a.cell.x), floor_div(py, a.cell.y)
    // The menu is painted OVER the panels, so it is asked before the strip (MENU.md §6): a pixel
    // it holds is not the panel's under it. THE TWO THAT COME BACK ARE PIXELS for the menu and
    // cells for a panel, because a popup is not on the cell lattice and a document is (§11).
    if _, on := menu_hit(a, px, py); on {
        return PANEL_MENU, px, py
    }
    // A reserved menubar row pushes every panel down one, so the row a pixel lands on is the
    // window's minus what the bar kept — which is where the frame put the strip (MENU.md §4).
    row := win - a.frame.body.y
    it := panel_spans(a)
    if i := strip.hit(a.strip, it, f32(px)); i >= 0 && row >= 0 && row < a.panels[i].grid.rows {
        return i, floor_div(px - int(strip.span(a.strip, it, i).x), a.cell.x), row
    }
    return -1, col, row
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

// Which panel wears the caret. The armed picker's target, so steering is visible with no second
// mark to invent: the caret is already what says where the next thing lands (§3).
panel_marked :: proc(a: ^App) -> int {
    if p, armed := a.pending.(input.Pending_Pick); armed {
        return p.target
    }
    return a.focus
}

// Move the mark. `panel_marked` reads it and this writes it, so a verb that lands somewhere says
// so once and the gesture it is inside decides what that means: the picker's target while one is
// armed, the focus otherwise.
panel_aim :: proc(a: ^App, i: int) {
    if p, armed := a.pending.(input.Pending_Pick); armed {
        p.target = clamp(i, 0, len(a.panels) - 1)
        a.pending = p // the same captured line, so this is the one write that must not free it
        panels_relayout(a) // the camera follows the mark, and the mark just moved
        return
    }
    panel_focus(a, i)
}

// The rectangle a document was last drawn in. A live slot the strip is not showing still has a
// viewport the kernel moves (§11) and still needs a page height, and the focused panel's is the
// only honest answer for a document you cannot see.
doc_rect :: proc(a: ^App, id: store.Id) -> Cells {
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

package main

import "core:fmt"
import "core:strings"
import "../gfx"
import "../input"
import "../store"
import "../uni"

// The ring while alt is held (§11): the lane `alt+N` addresses, down the side of the panel it
// addresses it in. A number you have to remember is state that is not on screen, which is the
// one thing §1 exists to kill, and this is the cheapest place to put it back.
//
// It is the FOCUSED panel's column because that is the panel `alt+N` acts on (PANELS.md §3).
// One in the middle of the screen would be a single answer for a strip that has two lanes on it.
//
// Drawn into the panel's OWN grid, after the document and before the menubar: the panel's clip
// and its paint carry it, so there is no layer, no origin of its own and no second paint pass.
// That is what the menubar needs (MENU.md §4) and what this does not.

// `[switcher] show`. Titles are what a column of a lane is for: `3` says nothing that
// `3  routing.odin` does not say better, and a lane keeps its gaps, so the numbers alone read as
// `1 2 4 7` with no reason on screen for the jumps. `numbers` is the narrow one for anyone who
// wants the digits back.
Switcher_Show :: enum u8 {
    Titles,
    Numbers,
}

// A cell of lead before the text. The column follows what is IN it: nine sessions is three cells
// wide, and a lane of long names is as wide as the longest one it can afford.
SWITCHER_PAD :: 1

// And never wider than this share of the panel. A column that can cover the document it is
// naming is not telling you where you are.
SWITCHER_SHARE :: 2

// One row of the column. The lane's name is a row with nowhere to go, which is what keeps the
// window arithmetic below over one list.
@(private = "file")
Switcher_Row :: struct {
    text: string,
    on:   bool, // the slot this row goes to is the one the panel is standing in
}

// --- the hold ---

// Alt down and alt up. A modifier is never a chord and never reaches the bind table, so the
// modifier's own press and release are the one place a hold can be seen (input.odin).
//
// Set only over a CLEAR pending, and cleared only while it is still ours: the union frees what
// it replaces, and an armed picker's captured line, a primer's label and the open command line
// are none of them ours to free. The cost is no column under those three, which is the same
// trade `alt+N` itself makes there.
//
// The set is per SIDE, not one bool: with both alts down, the first release must leave the
// column up for the one still held.
switcher_hold :: proc(a: ^App, code: input.Code, down: bool) {
    side: input.Switcher_Alt
    switch input.key_name(code) {
    case "LALT":
        side = .Left
    case "RALT":
        side = .Right
    case:
        return
    }
    sw, ours := a.pending.(input.Pending_Switcher)
    if !down {
        if !ours {
            return
        }
        sw.alts -= {side}
        if sw.alts == {} {
            input.pending_set(&a.pending)
        } else {
            input.pending_set(&a.pending, sw)
        }
        return
    }
    if ours {
        sw.alts += {side}
        input.pending_set(&a.pending, sw)
        return
    }
    if a.pending == nil {
        input.pending_set(&a.pending, input.Pending_Switcher{{side}})
    }
}

// The window lost the keyboard, or alt came up. A release delivered somewhere else would leave
// the column up over a panel nobody is typing into.
switcher_drop :: proc(a: ^App) {
    if _, up := a.pending.(input.Pending_Switcher); up {
        input.pending_set(&a.pending)
    }
}

// --- the column ---

switcher_draw :: proc(a: ^App) {
    if _, up := a.pending.(input.Pending_Switcher); !up {
        return
    }
    p := panel_focused(a)
    rows := switcher_rows(a)
    w := switcher_width(rows, p.body)
    if w <= 0 || p.body.h <= 0 || len(rows) == 0 {
        return
    }
    th, ground := a.theme, gfx.opaque(ground_bg(a))
    // TOP TO BOTTOM, and not down to the last entry: a column that stops where the slots do
    // reads as a popup sitting on the text. This is a SIDE of the panel, and a side runs the
    // height of it. The ground is the surface behind the panels, so the column reads at the
    // same depth as a gap does.
    blank := switcher_fit("", w)
    for y in 0 ..< p.body.h {
        gfx.grid_write(&p.grid, p.body.x, p.body.y + y, blank, ground.rgb, ground)
    }
    first := switcher_window(len(rows), switcher_here(rows), p.body.h)
    for i in first ..< min(len(rows), first + p.body.h) {
        r := rows[i]
        fg, bg := th[.Fg], ground
        switch {
        case r.on:
            // the slot you are in, filled the way a caret is
            fg, bg = th[.Bg], gfx.opaque(th[.Accent])
        case i == 0 && a.config.switcher == .Titles:
            fg = th[.Dim] // the lane's name: what the numbers are numbers OF, not one of them
        }
        gfx.grid_write(&p.grid, p.body.x, p.body.y + i - first, switcher_fit(r.text, w), fg, bg)
    }
}

// The lane, then its live slots in their own numbers, then N0 when anything has needed it. Gaps
// are skipped and NOT renumbered: the column has to read the way `alt+N` does (ring.odin).
@(private = "file")
switcher_rows :: proc(a: ^App) -> []Switcher_Row {
    out := make([dynamic]Switcher_Row, context.temp_allocator)
    l := lane_current(a)
    if l == nil {
        return out[:]
    }
    // Not in `numbers`, where a name would widen the whole column past the digits it is for.
    if a.config.switcher == .Titles {
        append(&out, Switcher_Row{kind_name(a, l.kind), false})
    }
    here := ring_slot(a)
    for s, i in l.slots {
        if s.live {
            append(&out, switcher_row(a, i + 1, s.doc, i + 1 == here))
        }
    }
    if a.ring.system.live {
        append(&out, switcher_row(a, SLOT_ZERO, a.ring.system.doc, here == SLOT_ZERO))
    }
    return out[:]
}

@(private = "file")
switcher_row :: proc(a: ^App, slot: int, doc: store.Id, on: bool) -> Switcher_Row {
    tag := slot_tag(slot)
    if a.config.switcher == .Numbers {
        return {tag, on}
    }
    return {fmt.tprintf("%s  %s", tag, doc_title(a, doc)), on}
}

// The widest row it can afford. Zero rows is zero width, which is what stops an empty lane
// drawing a bar of nothing down the panel.
@(private = "file")
switcher_width :: proc(rows: []Switcher_Row, body: Cells) -> int {
    w := 0
    for r in rows {
        w = max(w, switcher_cells(r.text))
    }
    return w == 0 ? 0 : min(w + 2 * SWITCHER_PAD, max(body.w / SWITCHER_SHARE, 0))
}

// CELLS, not runes: a wide rune paints two. Floored at one because grid_write spends a cell on
// every rune, combining marks included.
@(private = "file")
switcher_cells :: proc(text: string) -> (n: int) {
    for r in text {
        n += max(uni.rune_width(r), 1)
    }
    return
}

@(private = "file")
switcher_here :: proc(rows: []Switcher_Row) -> int {
    for r, i in rows {
        if r.on {
            return i
        }
    }
    return 0
}

// The row you are on, centred, clamped at both ends. A lane with more slots than the panel has
// rows still has to show the one you are standing in.
@(private = "file")
switcher_window :: proc(n, on, rows: int) -> int {
    return clamp(on - rows / 2, 0, max(0, n - rows))
}

// The row as the column draws it: the lead, the text cut to keep the trailing pad, then padded
// to the width. The fill is part of the STRING, so one write paints the row and the ground
// under it in one pass. A wide rune gets a blank cell after it — grid_write advances one cell a
// rune, and the glyph spills into that blank.
@(private = "file")
switcher_fit :: proc(text: string, w: int) -> string {
    b := strings.builder_make(context.temp_allocator)
    n := 0
    for n < min(SWITCHER_PAD, w) {
        strings.write_rune(&b, ' ')
        n += 1
    }
    for r in text {
        cw := max(uni.rune_width(r), 1)
        if n + cw > w - SWITCHER_PAD {
            break
        }
        strings.write_rune(&b, r)
        for _ in 1 ..< cw {
            strings.write_rune(&b, ' ')
        }
        n += cw
    }
    for n < w {
        strings.write_rune(&b, ' ')
        n += 1
    }
    return strings.to_string(b)
}

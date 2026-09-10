package main

import "core:fmt"
import "../gfx"
import "../input"
import "../store"

// The bar: the kernel's one row, at the bottom of every frame (CHROME.md §11). What it SAYS is
// here and what it is drawn ON is the frame's box (frame_paint.odin); the command line borrows
// the row while it is open and is its own file.

// How much darker than a document the bar's row is. Deeper than the ground between two panels,
// so the three layers read in order: a panel, the gap beside it, the line under both. The box
// and the cells the line fills read it both, so the two cannot end up two darknesses.
BAR_BEHIND :: 45

// The theme the bar's row is drawn in: the same one with a darker `Bg`. Gruvbox has no token
// under `Bg` and a colour written here would break every other theme, so the shade is derived
// (§8) — and passing a THEME rather than a colour pair is what lets the one renderer draw the
// command line without learning that it is one (§5).
bar_theme :: proc(th: gfx.Theme) -> gfx.Theme {
    out := th
    out[.Bg] = gfx.theme_behind(th, BAR_BEHIND)
    return out
}

// The bar's one row (§11). A pending state outranks a message, because a capture the user
// cannot see is invisible modality; a message outranks the resting line.
bar_text :: proc(a: ^App) -> string {
    if label := input.pending_describe(a.pending); label != "" {
        return label
    }
    if a.message != "" {
        return a.message
    }
    // Which PANEL, once there is more than one: the bar is global (§2), so it has to say which
    // of them it is answering for. `@N` is stage 4's spelling for a panel, used here first.
    tag := len(a.panels) > 1 ? fmt.tprintf("@%d ", a.focus + 1) : ""
    if ring_slot(a) == SLOT_ZERO {
        return fmt.tprintf("%sN0  the terminal oket runs things in", tag)
    }
    if s := ring_focused(a); s != nil {
        // A trail is half-visible state: the carets are drawn, the count and the way out are not
        // (VIEWS.md §4). Escape puts one down ahead of every row that claims the key, and no row
        // is what describe could read out, so the bar is where that is said.
        trail := ""
        if doc := store.store_doc(&a.docs, s.doc); doc != nil && len(doc.cursors) > 1 {
            trail = fmt.tprintf("  %d carets, esc puts them down", len(doc.cursors))
        }
        return fmt.tprintf("%s%s %s  %s%s", tag, kind_name(a, doc_kind(a, s.doc)),
                           slot_tag(ring_slot(a)), doc_title(a, s.doc), trail)
    }
    if tag != "" {
        return fmt.tprintf("%sempty; alt+N opens something here", tag)
    }
    return "esc quits, f1 describes a chord, alt+c opens the command line"
}

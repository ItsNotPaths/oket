package main

import "core:fmt"
import "../gfx"
import "../input"
import "../store"

// The kernel's own screen, drawn with zero plugins loaded: the recovery floor (§7, §13) and
// where kernel-level notices live. A document like any other once §5 exists.

screen_draw :: proc(g: ^gfx.Grid, th: gfx.Theme, a: ^gfx.Atlas) {
    gfx.grid_clear(g, th[.Fg], th[.Bg])
    y := 1
    x := gfx.grid_write(g, 2, y, "oket ", th[.Accent], th[.Bg])
    gfx.grid_write(g, x, y, version_text(), th[.Dim], th[.Bg])
    y += 2

    if gfx.atlas_is_fallback(a) {
        gfx.grid_write(g, 2, y, "! no system font: drawing with the built-in fallback atlas",
                       th[.Alert], th[.Bg])
        y += 2
    }

    // Smoke test for the glyph ranges the fallback promises; a row of tofu is visible.
    SAMPLES :: [?]string {
        "the quick brown fox 0123456789",
        "ÀÉÎÕÜ ñ ç ß « » ± ÷",
        "─│┌┐└┘├┤┬┴┼ ═║",
        "░▒▓█▀▄",
    }
    w := 34
    gfx.grid_box(g, 2, y, w, len(SAMPLES) + 2, th[.Dim], th[.Bg])
    gfx.grid_write(g, 4, y, " glyph check ", th[.Dim], th[.Bg])
    for s, i in SAMPLES {
        gfx.grid_write(g, 4, y + 1 + i, s, th[.Fg], th[.Bg])
    }
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
    if ring_slot(a) == SLOT_SYSTEM {
        return fmt.tprintf("%sN#  the system session", tag)
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

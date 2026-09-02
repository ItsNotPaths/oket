package main

import "../gfx"

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

    gfx.grid_write(g, 0, g.rows - 1, bar_text(), th[.Dim], th[.Bg])
}

// The bar's one row (§11); one line until a ring or pending state outranks it.
bar_text :: proc() -> string {
    return "esc quits"
}

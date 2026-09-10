package main

import "../gfx"

// The kernel's own screen, drawn with zero plugins loaded: the recovery floor (§7, §13) and
// where kernel-level notices live. A document like any other once §5 exists.

screen_draw :: proc(g: ^gfx.Grid, th: gfx.Theme, a: ^gfx.Atlas) {
    ground := gfx.opaque(th[.Bg])
    gfx.grid_clear(g, th[.Fg], ground)
    y := 1
    x := gfx.grid_write(g, 2, y, "oket ", th[.Accent], ground)
    gfx.grid_write(g, x, y, version_text(), th[.Dim], ground)
    y += 2

    if gfx.atlas_is_fallback(a) {
        gfx.grid_write(g, 2, y, "! no system font: drawing with the built-in fallback atlas",
                       th[.Alert], ground)
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
    gfx.grid_box(g, 2, y, w, len(SAMPLES) + 2, th[.Dim], ground)
    gfx.grid_write(g, 4, y, " glyph check ", th[.Dim], ground)
    for s, i in SAMPLES {
        gfx.grid_write(g, 4, y + 1 + i, s, th[.Fg], ground)
    }
}


package tests

import "core:strings"
import "core:testing"
import "../gfx"
import app "../oket"

// The gate for PANELS.md stage 1: the frame is two grids, not one. The chrome is the screen
// lattice and carries the bar; the panel is the window onto a document and carries nothing
// else. Nothing on screen moves, so what these assert is which grid a row landed on.

@(test)
the_panel_is_the_fit_without_the_bar :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    app.surface_fit(&a, 40, 10)
    testing.expect_value(t, a.chrome.cols, 40)
    testing.expect_value(t, a.chrome.rows, 10)
    testing.expect_value(t, panel_grid(&a).cols, 40)
    testing.expect_value(t, panel_grid(&a).rows, 9)
}

// The gate's own sentence: a panel snapshot is its own text block. The document is on the panel
// and the bar is on the chrome, and neither grid holds a line of the other.
@(test)
the_panel_diffs_without_the_bar_in_it :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-panel-split")
    if !ok {
        return
    }
    defer close_app(&a)

    panel := gfx.grid_snapshot(panel_grid(&a), context.temp_allocator)
    chrome := gfx.grid_snapshot(&a.chrome, context.temp_allocator)
    bar := app.bar_text(&a)

    testing.expect(t, strings.contains(panel, "alpha.txt"), panel)
    testing.expect_value(t, len(strings.split_lines(panel, context.temp_allocator)), 3)
    testing.expect(t, !strings.contains(panel, bar), panel)

    rows := strings.split_lines(chrome, context.temp_allocator)
    testing.expect_value(t, len(rows), 4)
    testing.expect(t, strings.has_prefix(rows[3], bar), chrome)
    testing.expect(t, !strings.contains(rows[0], "alpha.txt"), chrome)
}

// A window one row tall is all bar and no panel. A grid of no rows is legal and draws nothing,
// which is what keeps one-panel mode from being a special case at the small end.
@(test)
a_one_row_window_leaves_no_panel :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-panel-tiny")
    if !ok {
        return
    }
    defer close_app(&a)

    app.surface_fit(&a, 20, 1)
    app.surface_draw(&a)

    testing.expect_value(t, panel_grid(&a).rows, 0)
    testing.expect_value(t, app.panel_focused(&a).body.h, 0)
    chrome := gfx.grid_snapshot(&a.chrome, context.temp_allocator)
    testing.expect_value(t, len(strings.split_lines(chrome, context.temp_allocator)), 1)
    testing.expect(t, strings.has_prefix(app.bar_text(&a), chrome), chrome) // clipped at 20

    // And back out: the panel regrows from the zeroed grid the no-panel state left behind.
    app.surface_fit(&a, 20, 5)
    testing.expect_value(t, panel_grid(&a).cols, 20)
    testing.expect_value(t, panel_grid(&a).rows, 4)
}

// The scissor is the one piece of the split a text diff cannot see: GL counts its box from the
// bottom of the window and every rectangle above counts from the top.
@(test)
a_clip_flips_to_gls_corner :: proc(t: ^testing.T) {
    x, y, w, h := gfx.painter_scissor({4, 10, 100, 40}, 200)
    testing.expect_value(t, x, i32(4))
    testing.expect_value(t, y, i32(150))
    testing.expect_value(t, w, i32(100))
    testing.expect_value(t, h, i32(40))
}


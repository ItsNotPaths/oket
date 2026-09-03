package tests

import "core:strings"
import "core:testing"
import "../gfx"
import app "../oket"

// The gates for PANELS.md stages 1 and 2. Stage 1: the frame is two grids, not one — the chrome
// is the screen lattice and carries the bar, the panel is the window onto a document and carries
// nothing else. Stage 2: the panel is the UNIT — it holds the cursor into the ring, the rectangle
// a click is placed against and the hover, and a cell is its cell before it is a number.
//
// Nothing on screen moves in either, so what these assert is which grid a row landed on and
// which structure a number is read off.

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

// --- stage 2: the panel is the unit ---

// The ring holds the documents; where you are in them is the panel's (§2). `alt+N` moves the
// FOCUSED PANEL, so the lane and the slot the ring used to carry are read off the panel now.
@(test)
the_cursor_into_the_ring_is_the_panels :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-panel-cursor")
    if !ok {
        return
    }
    defer close_app(&a)

    p := app.panel_focused(&a)
    testing.expect_value(t, app.ring_lane(&a), p.at.lane)
    testing.expect_value(t, app.ring_slot(&a), p.at.slot)
    testing.expect_value(t, p.at.slot, 1)

    second := listing_doc(&a, dir) // the same kind, so the same lane
    app.ring_add(&a, second)
    testing.expect_value(t, app.panel_focused(&a).at.slot, 2)
    testing.expect_value(t, app.ring_focused(&a).doc, second)
    testing.expect_value(t, app.panel_focused(&a).prev.slot, 1) // alt+`, per panel
}

// A cell number means nothing until you know whose grid it counts from (§7), so the hit test
// answers a panel first. The bar's row belongs to no panel and stays in chrome cells.
@(test)
a_cell_belongs_to_a_panel_before_it_is_a_cell :: proc(t: ^testing.T) {
    a, ok := bare_app(20, 5) // four rows of panel, then the bar
    if !ok {
        return
    }
    defer close_app(&a)

    pn, x, y := app.panel_hit(&a, 3, 2)
    testing.expect_value(t, pn, 0)
    testing.expect_value(t, x, 3)
    testing.expect_value(t, y, 2)

    pn, _, y = app.panel_hit(&a, 3, 4)
    testing.expect_value(t, pn, -1)
    testing.expect_value(t, y, 4) // unshifted: the chrome is the lattice it was measured on

    pn, _, _ = app.panel_hit(&a, 99, 0)
    testing.expect_value(t, pn, -1)
}

// A document the strip is not showing still has a viewport the kernel moves (§11), and a page
// still has to mean a number of lines. The focused panel answers for it.
@(test)
a_document_off_the_strip_still_has_a_rectangle :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-panel-rect")
    if !ok {
        return
    }
    defer close_app(&a)

    shown := app.ring_focused(&a).doc
    off := scratch_doc(&a, "off", "one\ntwo\n")
    p := app.panel_focused(&a)
    p.body = {0, 0, 7, 3}

    testing.expect_value(t, app.doc_rect(&a, shown), p.body)
    testing.expect_value(t, app.doc_rect(&a, off), p.body)
}

// Hover is the panel's, because the pointer is over one of them (§8). Leaving every panel — the
// bar's row, or the space past the strip — puts the underline away.
@(test)
hover_belongs_to_the_panel_under_the_pointer :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-panel-hover")
    if !ok {
        return
    }
    defer close_app(&a)

    app.binds_parse(&a, "[surface]\nclick = exec :open <path>\n", "binds.conf")

    app.hover_update(&a, 0, 2, 1)
    testing.expect(t, app.panel_focused(&a).hover.on, "the name a bound click acts on is not underlined")

    app.hover_update(&a, 7, 2, 1) // a panel the strip does not have
    testing.expect(t, !app.panel_focused(&a).hover.on, "a panel past the strip underlined something")

    app.hover_update(&a, 0, 2, 1)
    app.hover_update(&a, -1, 2, 3) // the bar's row
    testing.expect(t, !app.panel_focused(&a).hover.on, "the pointer left the strip and the underline stayed")
}

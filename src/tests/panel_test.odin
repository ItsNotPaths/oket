package tests

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../gfx"
import app "../oket"

// The gates for PANELS.md stages 1, 2 and 3. Stage 1: the frame is two grids, not one — the
// chrome is the screen lattice and carries the bar, the panel is the window onto a document and
// carries nothing else. Stage 2: the panel is the UNIT — it holds the cursor into the ring, the
// rectangle a click is placed against and the hover, and a cell is its cell before it is a
// number. Stage 3 is the first one you can see: a strip longer than one, gaps, widths and a
// camera.
//
// A cell is one pixel in these, because bare_app leaves surface_fit its default: the strip is
// pixels and the grids are cells, and at 1:1 the two read as the same number.

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

// --- stage 3: more than one panel ---

// A new panel stands on NOTHING (§2: a live slot is in at most one panel), and it takes the
// lane it was opened from, so `alt+N` there addresses the numbers you were just looking at.
@(test)
a_new_panel_stands_on_nothing_in_the_lane_it_came_from :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-panel-open")
    if !ok {
        return
    }
    defer close_app(&a)

    lane := app.ring_lane(&a)
    app.panel_open(&a)

    testing.expect_value(t, len(a.panels), 2)
    testing.expect_value(t, a.focus, 1)
    testing.expect_value(t, app.ring_lane(&a), lane)
    testing.expect_value(t, app.ring_slot(&a), 0)
    testing.expect(t, app.ring_focused(&a) == nil, "a fresh panel took a document off another one")
}

// The two axes do not interfere (§3): walking the strip changes which panel has focus and
// nothing about which slot holds what. Clamped at both ends, because a strip is not a carousel.
@(test)
walking_the_strip_moves_no_document :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-panel-walk")
    if !ok {
        return
    }
    defer close_app(&a)

    first := app.ring_focused(&a).doc
    app.panel_open(&a)
    app.ring_add(&a, listing_doc(&a, dir))
    second := app.ring_focused(&a).doc

    app.panel_step(&a, -1)
    testing.expect_value(t, a.focus, 0)
    testing.expect_value(t, app.ring_focused(&a).doc, first)
    app.panel_step(&a, -1) // the left end
    testing.expect_value(t, a.focus, 0)

    app.panel_step(&a, +1)
    testing.expect_value(t, app.ring_focused(&a).doc, second)
    app.panel_step(&a, +1) // the right end
    testing.expect_value(t, a.focus, 1)
}

// The viewport lives on the SLOT, so two panels showing one would fight over it (§2). Asking for
// a slot another panel is standing on swaps the two rather than refusing: what `alt+N` promised
// is that the focused panel's content changes, and it does.
@(test)
two_panels_never_stand_on_one_slot :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-panel-swap")
    if !ok {
        return
    }
    defer close_app(&a)

    first := app.ring_focused(&a).doc
    app.panel_open(&a)
    app.ring_add(&a, listing_doc(&a, dir))
    second := app.ring_focused(&a).doc

    testing.expect(t, app.ring_goto(&a, 1), "slot 1 refused a panel that was not standing on it")
    testing.expect_value(t, app.ring_focused(&a).doc, first)
    testing.expect_value(t, app.panel_get(&a, 0).at.slot, 2)
    testing.expect_value(t, app.panel_slot(&a, app.panel_get(&a, 0)).doc, second)
}

// The panel goes, the documents stay (§3's gate). The ring renumbers nothing, and the strip
// never empties: the last panel is a strip of length one, which is where this started.
@(test)
closing_a_panel_renumbers_nothing :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-panel-close")
    if !ok {
        return
    }
    defer close_app(&a)

    first := app.ring_focused(&a).doc
    app.panel_open(&a)
    app.ring_add(&a, listing_doc(&a, dir))
    second := app.ring_focused(&a).doc
    lane := app.ring_lane(&a)

    testing.expect(t, app.panel_close(&a), a.message)
    testing.expect_value(t, len(a.panels), 1)
    testing.expect_value(t, a.focus, 0)
    testing.expect_value(t, app.ring_focused(&a).doc, first)
    // Both slots still hold what they held, at the numbers they held it at.
    testing.expect_value(t, app.lane_get(&a.ring, lane, 1).doc, first)
    testing.expect_value(t, app.lane_get(&a.ring, lane, 2).doc, second)

    testing.expect(t, !app.panel_close(&a), "the strip emptied itself")
    testing.expect_value(t, len(a.panels), 1)
}

// Two widths and no more (§5), and a gap is pixels between two panels. At one pixel per cell the
// strip's arithmetic reads in columns: two halves of a 50-column view, less half a gap each.
@(test)
the_size_toggle_is_the_whole_sizing_model :: proc(t: ^testing.T) {
    a, ok := bare_app(50, 5)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.gap = 4

    app.panel_open(&a)
    app.panel_resize(&a)
    app.panel_step(&a, -1)
    app.panel_resize(&a)

    testing.expect_value(t, app.panel_get(&a, 0).grid.cols, 23) // 25 less half a gap
    testing.expect_value(t, app.panel_get(&a, 1).grid.cols, 23)
    testing.expect_value(t, a.strip.camera, f32(0)) // both halves are on screen at once

    // And back to full, which is the view less the one gap it now has a neighbour across.
    app.panel_resize(&a)
    testing.expect_value(t, app.panel_get(&a, 0).grid.cols, 48)
}

// A click lands in the panel it was over, and the column counts from THAT panel's grid (§7).
// The gap between them belongs to neither.
@(test)
a_click_lands_in_the_panel_it_was_over :: proc(t: ^testing.T) {
    a, ok := bare_app(50, 5)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.gap = 4

    app.panel_open(&a)
    app.panel_resize(&a)
    app.panel_step(&a, -1)
    app.panel_resize(&a) // two halves, 23 columns each, four pixels of air between them

    pn, x, y := app.panel_hit(&a, 3, 1)
    testing.expect_value(t, pn, 0)
    testing.expect_value(t, x, 3)
    testing.expect_value(t, y, 1)

    pn, _, _ = app.panel_hit(&a, 24, 1) // the gap
    testing.expect_value(t, pn, -1)

    pn, x, _ = app.panel_hit(&a, 30, 1)
    testing.expect_value(t, pn, 1)
    testing.expect_value(t, x, 3) // its own column 3, not the screen's column 30
}

// The camera follows focus (§5). A panel off screen scrolls into view; one already on it does
// not move the strip. It snaps here because the fixture leaves `tau` zero, which is motion off:
// the layout is what this file is about, and the motion onto it is motion_test.odin's.
@(test)
the_camera_follows_focus :: proc(t: ^testing.T) {
    a, ok := bare_app(50, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    app.panel_open(&a) // two full-width panels: the second is a whole view to the right
    testing.expect_value(t, a.strip.camera, f32(50))
    pn, _, _ := app.panel_hit(&a, 10, 1)
    testing.expect_value(t, pn, 1) // the first is off the left edge, at a negative origin

    app.panel_step(&a, -1)
    testing.expect_value(t, a.strip.camera, f32(0))
    pn, _, _ = app.panel_hit(&a, 10, 1)
    testing.expect_value(t, pn, 0)
}

// §3's sentence, drawn: the caret is in the focused panel and nowhere else, so which lane
// `alt+N` counts in is on screen rather than remembered.
@(test)
only_the_focused_panel_draws_the_caret :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-panel-caret")
    if !ok {
        return
    }
    defer close_app(&a)

    app.panel_open(&a)
    app.ring_add(&a, listing_doc(&a, dir))
    app.surface_draw(&a)

    testing.expect(t, marked(app.panel_get(&a, 1)), "the focused panel drew no caret")
    testing.expect(t, !marked(app.panel_get(&a, 0)), "an unfocused panel drew one")

    app.panel_step(&a, -1)
    app.surface_draw(&a)
    testing.expect(t, marked(app.panel_get(&a, 0)), "focus moved and the caret did not")
    testing.expect(t, !marked(app.panel_get(&a, 1)), "the caret stayed behind in the old panel")
}

// Reverse video is the caret and the selection both (view.odin), so this is what "drawn as
// focused" means on a grid.
@(private = "file")
marked :: proc(p: ^app.Panel) -> bool {
    for c in p.grid.cells {
        if .Reverse in c.attrs {
            return true
        }
    }
    return false
}

// The gate: a browser and two editors on screen at once, `alt+N` addressing the focused panel's
// lane, and closing a panel renumbering nothing. Three kinds of document, three panels, one
// store, one bind table and one io thread — which is the whole of what §1 said two instances
// could not do.
@(test)
a_browser_and_two_editors_at_once :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-panel-gate", "plugins/browser", "plugins/edit")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    for plugin in ([?]string{"browser", "edit"}) {
        if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, plugin)), a.message) {
            return
        }
    }

    id, opened := app.files_open(&a, a.home)
    if !testing.expect(t, opened, a.message) {
        return
    }
    app.ring_add(&a, id)
    for file in ([?]string{"alpha.txt", "beta.txt"}) {
        path, _ := filepath.join({a.home, file}, context.temp_allocator)
        app.panel_open(&a)
        app.cl_exec(&a, fmt.tprintf(":open %s", path))
    }
    app.surface_draw(&a)

    testing.expect_value(t, len(a.panels), 3)
    kinds := [3]string{}
    for i in 0 ..< 3 {
        app.panel_focus(&a, i)
        kinds[i] = app.kind_name(&a, app.doc_kind(&a, app.ring_focused(&a).doc))
    }
    testing.expect_value(t, kinds, [3]string{"files", "edit", "edit"})

    // The lane the numbers count in is the FOCUSED panel's, and it differs across the strip.
    app.panel_focus(&a, 0)
    files := app.ring_lane(&a)
    app.panel_focus(&a, 2)
    edit := app.ring_lane(&a)
    testing.expect(t, files != edit, "a browser and an editor landed in one lane")
    testing.expect_value(t, app.ring_slot(&a), 2)

    // alt+2 from panel 1, which is edit slot 1: slot 2 is live in panel 2, so the two swap.
    beta := app.ring_focused(&a).doc
    app.panel_focus(&a, 1)
    alpha := app.ring_focused(&a).doc
    app.handle_chord(&a, chord("AE02", {.Alt}))
    testing.expect_value(t, app.ring_focused(&a).doc, beta)
    app.panel_focus(&a, 2)
    testing.expect_value(t, app.ring_focused(&a).doc, alpha)

    // And the panel closes without the ring noticing: two panels, three documents, same numbers.
    testing.expect(t, app.panel_close(&a), a.message)
    testing.expect_value(t, len(a.panels), 2)
    testing.expect_value(t, app.lane_get(&a.ring, edit, 1).doc, alpha)
    testing.expect_value(t, app.lane_get(&a.ring, edit, 2).doc, beta)
    testing.expect_value(t, app.lane_get(&a.ring, files, 1).doc, id)
}

// A click is placed against the rectangle the active document was drawn in, so the funnel has to
// know WHOSE cells it arrived in (§7). The line is on the chrome and a document is on its panel:
// a gap click would otherwise move a panel's caret, and a click on the open line would move
// nothing at all.
@(test)
a_click_counts_from_the_grid_the_keys_are_aimed_at :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-panel-lattice")
    if !ok {
        return
    }
    defer close_app(&a)

    app.panel_open(&a)
    testing.expect_value(t, app.active_panel(&a), 1)
    app.panel_step(&a, -1)
    testing.expect_value(t, app.active_panel(&a), 0)

    app.cl_show(&a, ":")
    testing.expect_value(t, app.active_panel(&a), -1) // the bar's row, which is no panel's
    testing.expect_value(t, app.active_rect(&a), a.bar)
}

// --- stage 4: addressing ---

// One grammar for both axes (§4). A line carries one of each in either order, a bare number is
// still a ring slot, and anything else is reported rather than aimed somewhere.
@(test)
two_sigils_and_a_bare_number :: proc(t: ^testing.T) {
    for row in ([?]struct {
        text:   string,
        target: app.Target,
    } {
        {"", {}},
        {"3", {slot = 3}},
        {"#3", {slot = 3}},
        {"@2", {panel = 2}},
        {"@-1", {panel = -1, rel = true}},
        {"@+2 #4", {slot = 4, panel = 2, rel = true}},
        {"#4 @2", {slot = 4, panel = 2}},
    }) {
        target, _, ok := app.target_parse(row.text)
        testing.expectf(t, ok, "%q is not an address", row.text)
        testing.expectf(t, target == row.target, "%q parsed as %v", row.text, target)
    }
    for text in ([?]string{"x", "@", "#", "@0", "@+0", "#0", "-1", "#-1", "@2x"}) {
        _, bad, ok := app.target_parse(text)
        testing.expectf(t, !ok, "%q was taken for an address", text)
        testing.expect_value(t, bad, text)
    }
}

// A `#` is a comment where the shell would see one and a slot where a builtin would, so a ring
// address survives the chain splitter and a shell step still loses its trailing note.
@(test)
a_builtin_line_has_no_comments_in_it :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_parse(&a, ":open alpha.txt #2 && echo hi # a note")
    testing.expect_value(t, len(a.chain.steps), 2)
    testing.expect_value(t, a.chain.steps[0].text, "open alpha.txt #2")
    testing.expect_value(t, a.chain.steps[1].text, "echo hi")
}

// The gate: `@N` puts the file in that panel whatever kind it held, and the ring decides which
// slot — the panel was standing on a browser and now stands on an edit slot that did not exist.
@(test)
a_panel_takes_a_file_whatever_it_held :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-panel-aim", "plugins/browser", "plugins/edit")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    for plugin in ([?]string{"browser", "edit"}) {
        if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, plugin)), a.message) {
            return
        }
    }
    path, _ := filepath.join({a.home, "alpha.txt"}, context.temp_allocator)

    id, opened := app.files_open(&a, a.home)
    if !testing.expect(t, opened, a.message) {
        return
    }
    app.ring_add(&a, id)
    app.panel_open(&a)
    second, _ := app.files_open(&a, a.home) // panel 2, a browser of its own
    app.ring_add(&a, second)
    files := app.ring_lane(&a)
    app.panel_step(&a, -1) // and the keys back on panel 1

    app.cl_exec(&a, fmt.tprintf(":open %s @2", path))
    testing.expect_value(t, a.focus, 1) // the open takes focus with it
    testing.expect_value(t, app.kind_name(&a, app.doc_kind(&a, app.ring_focused(&a).doc)), "edit")
    testing.expect(t, app.ring_lane(&a) != files, "the file landed in the browser's lane")
    testing.expect_value(t, app.ring_slot(&a), 1) // its own lane's first free slot, not @2

    // The browser it displaced is where it was, at the number it had.
    testing.expect_value(t, app.lane_get(&a.ring, files, 1).doc, id)
    testing.expect_value(t, len(a.panels), 2)
}

// An address the strip cannot answer MAKES the panel, the way `ring_put` grows a lane to reach a
// slot. `@N` counts from the left; `@±N` is a walk, and it stops at the end it walks into.
@(test)
an_address_makes_the_panel_it_names :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-panel-reach")
    if !ok {
        return
    }
    defer close_app(&a)

    testing.expect_value(t, app.target_reach(&a, {panel = 3}), 2)
    testing.expect_value(t, len(a.panels), 3)

    app.panel_focus(&a, 0)
    testing.expect_value(t, app.target_reach(&a, {panel = -1, rel = true}), 0)
    testing.expect_value(t, len(a.panels), 4) // a new leftmost, and the old one moved right
    testing.expect_value(t, a.focus, 1)

    testing.expect_value(t, app.target_reach(&a, {panel = 9, rel = true}), 4)
    testing.expect_value(t, len(a.panels), 5) // a walk stops at the end, and makes one there
    testing.expect_value(t, app.target_reach(&a, {panel = 1, rel = true}), 2) // inside: nothing made
    testing.expect_value(t, len(a.panels), 5)
}

// A target that is not an address opens nothing at all: the file is not read and no panel is
// made, because the line said WHERE and the where was a typo.
@(test)
a_mistyped_target_opens_nothing :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-panel-typo")
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_exec(&a, fmt.tprintf(":open %s @two", dir))
    testing.expect_value(t, len(a.panels), 1)
    testing.expect(t, app.ring_get(&a, 2) == nil, "the open ran anyway")
    testing.expect(t, strings.contains(a.message, "@two"), a.message)
}

// `alt+shift+left` and `alt+shift+right`: the panel changes place, the documents do not, and the
// thing you were looking at is still the thing you are looking at. Clamped, like the walk.
@(test)
a_panel_moves_along_the_strip :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    app.panel_open(&a)
    app.panel_open(&a) // three panels, focus on the last
    app.panel_get(&a, 0).at = {0, 1}
    app.panel_get(&a, 2).at = {0, 3}
    testing.expect_value(t, a.focus, 2)

    app.panel_shift(&a, -1)
    testing.expect_value(t, a.focus, 1)
    testing.expect_value(t, app.panel_get(&a, 1).at.slot, 3) // it went with the focus
    testing.expect_value(t, app.panel_get(&a, 2).at.slot, 0) // and the neighbour came back

    app.panel_shift(&a, -1)
    testing.expect_value(t, a.focus, 0)
    testing.expect_value(t, app.panel_get(&a, 1).at.slot, 1)

    app.panel_shift(&a, -1) // off the end: a strip has two ends and this is one of them
    testing.expect_value(t, a.focus, 0)
    testing.expect_value(t, app.panel_get(&a, 0).at.slot, 3)
    testing.expect_value(t, len(a.panels), 3)
}

package tests

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:os"
import "core:testing"
import "../gfx"
import "../store"
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

// A new panel opens on the HOME PAGE, on a fresh document of its own (§2: a live slot is in
// at most one panel).
@(test)
a_new_panel_stands_on_the_home_page :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-panel-open")
    if !ok {
        return
    }
    defer close_app(&a)

    first := app.ring_focused(&a).doc
    app.panel_open(&a)

    testing.expect_value(t, len(a.panels), 2)
    testing.expect_value(t, a.focus, 1)
    s := app.ring_focused(&a)
    if !testing.expect(t, s != nil, "a new panel stood on nothing") {
        return
    }
    testing.expect_value(t, app.doc_kind(&a, s.doc), app.KIND_HOME)
    testing.expect(t, s.doc != first, "a fresh panel took a document off another one")

    // The panel itself still stands on nothing until something is put in it: `panel_make` is
    // the strip's, `panel_open` is the verb, and only the verb has an opinion about what shows.
    bare := app.panel_make(&a, 2)
    testing.expect_value(t, app.panel_get(&a, bare).at.slot, 0)
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
    panel_beside(&a)
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
    panel_beside(&a)
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

// A gap is pixels between two panels (§5). At one pixel per cell the strip's arithmetic reads in
// columns: two halves of a 50-column view, less half a gap each.
@(test)
two_halves_of_the_view_are_the_view_less_a_gap :: proc(t: ^testing.T) {
    a, ok := bare_app(50, 5)
    if !ok {
        return
    }
    defer close_app(&a)
    a.config.gap = 4

    app.panel_open(&a)
    panel_toggle(&a)
    app.panel_step(&a, -1)
    panel_toggle(&a)

    testing.expect_value(t, app.panel_get(&a, 0).grid.cols, 23) // 25 less half a gap
    testing.expect_value(t, app.panel_get(&a, 1).grid.cols, 23)
    testing.expect_value(t, a.strip.camera, f32(0)) // both halves are on screen at once

    // And back to full, which is the view less the one gap it now has a neighbour across.
    panel_toggle(&a)
    testing.expect_value(t, app.panel_get(&a, 0).grid.cols, 48)
}

// The sizing model is the ROW (§5): a list of percents is a cycle, so the same verb is a toggle,
// a three-way or a set depending on what the file says. The kernel names no widths of its own.
@(test)
a_width_list_is_a_cycle :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL)
    app.cl_exec(&a, ":width 100 50 33")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL / 2)
    app.cl_exec(&a, ":width 100 50 33")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL / 3)
    app.cl_exec(&a, ":width 100 50 33") // and round, which is what makes it a cycle
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL)

    // One percent is a set, and the words are the same numbers said another way.
    app.cl_exec(&a, ":width 25")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL / 4)
    app.cl_exec(&a, ":width third")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL / 3)

    // A panel at a percent the list does not name takes the first entry rather than nowhere.
    app.cl_exec(&a, ":width 80 40")
    testing.expect_value(t, app.panel_focused(&a).size, 80 * (app.WIDTH_FULL / 100))
}

// A third has no whole percent, so a typed number near one becomes the fraction itself: three
// panels at `:width 30` fill the strip, and three at a whole 33 leave a sliver of it empty.
@(test)
a_width_near_a_fraction_becomes_it :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    third := app.WIDTH_FULL / 3
    for typed in ([?]string{":width 30", ":width 33", ":width 34"}) {
        app.cl_exec(&a, typed)
        testing.expectf(t, app.panel_focused(&a).size == third, "%s is not a third", typed)
    }
    app.cl_exec(&a, ":width 67")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL * 2 / 3)
    app.cl_exec(&a, ":width 17")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL / 6)

    // Far from every fraction is left alone: a number nothing is near meant itself.
    app.cl_exec(&a, ":width 10")
    testing.expect_value(t, app.panel_focused(&a).size, 10 * (app.WIDTH_FULL / 100))
    app.cl_exec(&a, ":width 45")
    testing.expect_value(t, app.panel_focused(&a).size, 45 * (app.WIDTH_FULL / 100))
}

// The words say the fraction outright, so they are exact whatever the snap does.
@(test)
the_width_words_are_exact_fractions :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    for pair in ([?]struct{line: string, want: int} {
        {":width full", app.WIDTH_FULL},
        {":width half", app.WIDTH_FULL / 2},
        {":width third", app.WIDTH_FULL / 3},
        {":width quarter", app.WIDTH_FULL / 4},
    }) {
        app.cl_exec(&a, pair.line)
        testing.expectf(t, app.panel_focused(&a).size == pair.want, "%s", pair.line)
    }
}

// A percent the row cannot mean is REPORTED and sizes nothing. Clamping 200 to 100 would answer
// a typo with a layout, which is the silence §8 exists to prevent.
@(test)
a_percent_out_of_range_sizes_nothing :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_exec(&a, ":width 200")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL)
    testing.expect(t, strings.contains(a.message, "200"), a.message)

    app.cl_exec(&a, ":width 50 wide")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL) // not even the 50 it could read
    testing.expect(t, strings.contains(a.message, "wide"), a.message)

    // No percent at all is usage, not a no-op with no answer.
    app.cl_exec(&a, ":width @1")
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL)
    testing.expect(t, strings.contains(a.message, "<percent>"), a.message)
}

// `@N` on a width names a panel to SIZE, so it reaches one and never makes one: `:open` grows
// the strip because it has a document to put there, and this has nothing to put anywhere.
@(test)
a_width_reaches_a_panel_and_makes_none :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_exec(&a, ":width 50 @2")
    testing.expect_value(t, len(a.panels), 1)
    testing.expect_value(t, app.panel_focused(&a).size, app.WIDTH_FULL)
    testing.expect(t, strings.contains(a.message, "panel"), a.message)

    // With the panel there it is sized, and the focus stays where it was.
    app.panel_open(&a)
    app.panel_step(&a, -1)
    app.cl_exec(&a, ":width 50 @2")
    testing.expect_value(t, a.focus, 0)
    testing.expect_value(t, app.panel_get(&a, 0).size, app.WIDTH_FULL)
    testing.expect_value(t, app.panel_get(&a, 1).size, app.WIDTH_FULL / 2)
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
    panel_toggle(&a)
    app.panel_step(&a, -1)
    panel_toggle(&a) // two halves, 23 columns each, four pixels of air between them

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

    id, opened := app.files_open(&a, home_dir(a.home))
    if !testing.expect(t, opened, a.message) {
        return
    }
    app.ring_add(&a, id)
    for file in ([?]string{"alpha.txt", "beta.txt"}) {
        path, _ := filepath.join({home_dir(a.home), file}, context.temp_allocator)
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
        {"@2", {panel = 2, how = .Nth}},
        {"@-1", {panel = -1, how = .Step}},
        {"@+2 #4", {slot = 4, panel = 2, how = .Step}},
        {"#4 @2", {slot = 4, panel = 2, how = .Nth}},
        {"@=", {how = .Showing}},
        {"@= #4", {slot = 4, how = .Showing}},
        // Last sigil wins, and `@=` is on the same axis as `@N`: neither survives the other.
        {"@= @2", {panel = 2, how = .Nth}},
        {"@2 @=", {how = .Showing}},
        // `*` is an exact form on either axis, and last-wins holds against it both ways.
        {"@*", {how = .All}},
        {"#*", {slots = true}},
        {"#* #2", {slot = 2}},
        {"#2 #*", {slots = true}},
    }) {
        target, _, ok := app.target_parse(row.text)
        testing.expectf(t, ok, "%q is not an address", row.text)
        testing.expectf(t, target == row.target, "%q parsed as %v", row.text, target)
    }
    for text in ([?]string{"x", "@", "#", "@0", "@+0", "#0", "-1", "#-1", "@2x", "@=x", "#=",
                           "*"}) {
        _, bad, ok := app.target_parse(text)
        testing.expectf(t, !ok, "%q was taken for an address", text)
        testing.expect_value(t, bad, text)
    }

    // The picker rewrites only a BARE `@`; `@*` is already an address and keeps its aim.
    testing.expect_value(t, app.target_aim(":width 50 @*", 2), ":width 50 @*")
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
    path, _ := filepath.join({home_dir(a.home), "alpha.txt"}, context.temp_allocator)

    id, opened := app.files_open(&a, home_dir(a.home))
    if !testing.expect(t, opened, a.message) {
        return
    }
    app.ring_add(&a, id)
    app.panel_open(&a)
    second, _ := app.files_open(&a, home_dir(a.home)) // panel 2, a browser of its own
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

    testing.expect_value(t, app.target_reach(&a, {panel = 3, how = .Nth}, {}), 2)
    testing.expect_value(t, len(a.panels), 3)

    app.panel_focus(&a, 0)
    testing.expect_value(t, app.target_reach(&a, {panel = -1, how = .Step}, {}), 0)
    testing.expect_value(t, len(a.panels), 4) // a new leftmost, and the old one moved right
    testing.expect_value(t, a.focus, 1)

    testing.expect_value(t, app.target_reach(&a, {panel = 9, how = .Step}, {}), 4)
    testing.expect_value(t, len(a.panels), 5) // a walk stops at the end, and makes one there
    testing.expect_value(t, app.target_reach(&a, {panel = 1, how = .Step}, {}), 2) // inside: nothing made
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

    panel_beside(&a)
    panel_beside(&a) // three panels, focus on the last
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

// A second panel standing on NOTHING, for the tests that count slots. `panel_open` is the verb
// and the verb lands a home page in what it makes (panel.odin), which is a slot in the lane and
// would renumber everything these tests are asserting about.
@(private = "file")
panel_beside :: proc(a: ^app.App) {
    app.panel_focus(a, app.panel_make(a, a.focus + 1))
}

// The document a panel is standing on, for the two tests that ask where something went rather
// than what is drawn.
@(private = "file")
panel_doc :: proc(a: ^app.App, i: int) -> store.Id {
    s := app.panel_slot(a, app.panel_get(a, i))
    return s == nil ? store.Id{} : s.doc
}

// `@=` is the automatic half of the routing, and it is opt-in per ROW rather than a mode: a
// document already up goes to the panel that has it and the rest of the strip is left alone.
// The same open without it replaces the panel you are in, which is what every line with no `@`
// does — so the two policies are one word apart and both are greppable.
@(test)
an_open_can_go_to_the_panel_that_has_it :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-panel-showing", "plugins/edit")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "edit")), a.message) {
        return
    }
    note, _ := filepath.join({home_dir(a.home), "note.txt"}, context.temp_allocator)
    other, _ := filepath.join({home_dir(a.home), "other.txt"}, context.temp_allocator)
    for path in ([?]string{note, other}) {
        if err := os.write_entire_file(path, transmute([]u8)string("alpha\n")); err != nil {
            testing.expectf(t, false, "cannot write %s: %v", path, err)
            return
        }
    }

    app.cl_exec(&a, fmt.tprintf(":open %s", note))
    first := app.ring_focused(&a).doc
    app.panel_open(&a) // a second panel, and the keys with it
    app.cl_exec(&a, fmt.tprintf(":open %s", other))
    second := app.ring_focused(&a).doc
    testing.expect_value(t, a.focus, 1)

    // `@=`: the keys go to panel 1, and panel 2 keeps what it was holding.
    app.cl_exec(&a, fmt.tprintf(":open %s @=", note))
    testing.expect_value(t, a.focus, 0)
    testing.expect_value(t, panel_doc(&a, 0), first)
    testing.expect_value(t, panel_doc(&a, 1), second)
    testing.expect_value(t, len(a.panels), 2)

    // The same open with no `@` at all, from the other panel: the document comes to YOU, and
    // the panel that had it takes what you were holding (ring_move's swap).
    app.panel_focus(&a, 1)
    app.cl_exec(&a, fmt.tprintf(":open %s", note))
    testing.expect_value(t, a.focus, 1)
    testing.expect_value(t, panel_doc(&a, 1), first)
    testing.expect_value(t, panel_doc(&a, 0), second)

    // Nothing is showing a file that is not open, so `@=` lands where you are: one row covers
    // the document you have up and the one you do not.
    app.panel_focus(&a, 0)
    fresh, _ := filepath.join({home_dir(a.home), "third.txt"}, context.temp_allocator)
    if err := os.write_entire_file(fresh, transmute([]u8)string("beta\n")); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", fresh, err)
        return
    }
    app.cl_exec(&a, fmt.tprintf(":open %s @=", fresh))
    testing.expect_value(t, a.focus, 0)
    testing.expect_value(t, len(a.panels), 2)
    testing.expect_value(t, app.doc_title(&a, panel_doc(&a, 0)), fresh)

    // A document live in a slot no panel shows is not up anywhere: `@=` falls back to the
    // panel you are in, and the open is the ordinary move.
    app.cl_exec(&a, fmt.tprintf(":open %s @=", other))
    testing.expect_value(t, a.focus, 0)
    testing.expect_value(t, panel_doc(&a, 0), second)
    testing.expect_value(t, panel_doc(&a, 1), first)
    testing.expect_value(t, len(a.panels), 2)
}

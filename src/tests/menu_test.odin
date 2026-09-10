package tests

import "core:testing"
import "../gfx"
import "../menu"

// MENU.md §7's rule, as a test: the menubar is a piece, so this file builds a bar with a struct
// literal and never reaches for an App or a fixture. If it ever needs one, the menu has grown a
// dependency on binds, builtins or panels and it is not a reader any more.
//
// The bar below is the picture in §1, so the snapshots are that picture.

@(private = "file")
KIDS := [?]menu.Row {
    {chord = "alt+a", name = ":select-all", tag = "lsp", id = 10},
    {chord = "alt+h", name = ":dothing", tag = "lsp", id = 11},
    {chord = "alt+d", name = ":br.hidden", tag = "browser", id = 12},
}

@(private = "file")
CHORDS := [?]menu.Row {
    {chord = "alt+x", tag = ">", kids = KIDS[:]},
    {chord = "ctrl+f", tag = ">", kids = KIDS[:]},
}

@(private = "file")
FILE := [?]menu.Row {
    {chord = "alt+o", name = "file.open", doc = "open a file", id = 1},
    {name = ":q", doc = "close the window", id = 2},
}

@(private = "file")
MENUS := [?]menu.Menu {
    {name = "file", region = .Kernel, rows = FILE[:]},
    {name = "edit", region = .Kernel},
    {name = "view", region = .Kernel},
    {name = "panel", region = .Kernel},
    {name = "chords", region = .Chords, rows = CHORDS[:]},
    {name = "browser", region = .Plugin},
    {name = "lsp", region = .Plugin},
}

@(private = "file")
CHORDS_MENU :: 4

@(private = "file")
bar :: proc() -> menu.Bar {
    return {menus = MENUS[:], y = 0, cols = 80, rows = 24}
}

// The names, and a separator where the ownership changes: the kernel's namespaces, the shared
// sequence space, then one menu per plugin. Nothing on a menu says which region it is in twice.
@(test)
the_bar_is_names_and_a_separator_where_the_owner_changes :: proc(t: ^testing.T) {
    b := bar()
    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, b.cols, 1))
    defer gfx.grid_destroy(&g)

    menu.draw_bar(b, &g, gfx.DEFAULT_THEME, gfx.NOTHING)
    text := gfx.grid_snapshot(&g)
    defer delete(text)
    testing.expect_value(t, text, " file  edit  view  panel │ chords │ browser  lsp")
}

// A dropdown is a box of columns, and a column no row fills costs nothing: the chords menu holds
// bare chords and a popout mark, so it is thirteen cells wide and not the width of a name column
// nobody wrote in.
@(test)
a_dropdown_is_a_box_of_columns :: proc(t: ^testing.T) {
    b := bar()
    n := menu.nav(CHORDS_MENU)
    box := menu.drop_box(b, n)
    testing.expect_value(t, box, menu.Box{27, 1, 13, 4}) // under the first letter of `chords`

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, box.w, box.h))
    defer gfx.grid_destroy(&g)
    menu.draw_drop(b, n, &g, gfx.DEFAULT_THEME)

    text := gfx.grid_snapshot(&g)
    defer delete(text)
    testing.expect_value(
        t,
        text,
        `┌───────────┐
│ alt+x   > │
│ ctrl+f  > │
└───────────┘`,
    )
}

// A doc column is prose and stays left-aligned; only the tag is pushed right (§2). A row with no
// chord still lines its name up with the rows that have one.
@(test)
a_doc_column_is_prose_and_only_the_tag_is_pushed_right :: proc(t: ^testing.T) {
    b := bar()
    n := menu.nav(0)
    box := menu.drop_box(b, n)
    testing.expect_value(t, box, menu.Box{1, 1, 38, 4})

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, box.w, box.h))
    defer gfx.grid_destroy(&g)
    menu.draw_drop(b, n, &g, gfx.DEFAULT_THEME)

    text := gfx.grid_snapshot(&g)
    defer delete(text)
    testing.expect_value(
        t,
        text,
        `┌────────────────────────────────────┐
│ alt+o  file.open  open a file      │
│        :q         close the window │
└────────────────────────────────────┘`,
    )
}

// The popout hangs off the row that opened it: hard against the dropdown's right edge, level
// with that row, and each row naming its own owner (§1).
@(test)
a_popout_hangs_off_the_row_that_opened_it :: proc(t: ^testing.T) {
    b := bar()
    n := menu.nav(CHORDS_MENU)
    menu.down(b, &n) // the second primer, so the popout is level with it and not with the first
    menu.right(b, &n)
    testing.expect(t, menu.popped(n))

    drop, box := menu.drop_box(b, n), menu.kid_box(b, n)
    testing.expect_value(t, box.x, drop.x + drop.w)
    testing.expect_value(t, box.y, drop.y + 1 + n.row)
    testing.expect_value(t, box, menu.Box{40, 3, 31, 5})

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, box.w, box.h))
    defer gfx.grid_destroy(&g)
    menu.draw_kids(b, n, &g, gfx.DEFAULT_THEME)

    text := gfx.grid_snapshot(&g)
    defer delete(text)
    testing.expect_value(
        t,
        text,
        `┌─────────────────────────────┐
│ alt+a  :select-all      lsp │
│ alt+h  :dothing         lsp │
│ alt+d  :br.hidden   browser │
└─────────────────────────────┘`,
    )
}

// `enter` on a primer pops its children out and runs nothing; on a child it hands back the
// kernel's own id and says to run it. The package decides nothing else.
@(test)
enter_opens_a_primer_and_runs_a_child :: proc(t: ^testing.T) {
    b := bar()
    n := menu.nav(CHORDS_MENU)

    id, run := menu.enter(b, &n)
    testing.expect(t, !run, "a primer ran something")
    testing.expect(t, menu.popped(n))

    menu.down(b, &n)
    menu.down(b, &n)
    id, run = menu.enter(b, &n)
    testing.expect(t, run)
    testing.expect_value(t, id, 12) // the browser's row, third of the popout
}

// Six keys and no mode (§5). `left` gives the popout back before it gives the menu back, and
// `esc` does the same one step at a time — the second one is the kernel's to act on, because the
// menu itself is the pending state.
@(test)
left_and_esc_close_the_popout_before_the_menu :: proc(t: ^testing.T) {
    b := bar()
    n := menu.nav(CHORDS_MENU)
    menu.right(b, &n)
    testing.expect(t, menu.popped(n))

    menu.left(b, &n)
    testing.expect(t, !menu.popped(n))
    testing.expect_value(t, n.menu, CHORDS_MENU) // still the menu you were in

    menu.right(b, &n)
    testing.expect(t, !menu.esc(&n), "esc gave the menu back with a popout still out")
    testing.expect(t, !menu.popped(n))
    testing.expect(t, menu.esc(&n), "esc did not give the menu back")
}

// A bar is a ring: the last menu is one key from the first. Moving forgets the row, so a menu
// opens on its first row rather than on wherever a neighbour was left.
@(test)
the_bar_wraps_and_a_move_forgets_the_row :: proc(t: ^testing.T) {
    b := bar()
    n := menu.nav(0)
    menu.down(b, &n)
    menu.right(b, &n) // nothing hangs off a `file` row, so this is the next menu
    testing.expect_value(t, n.menu, 1)
    testing.expect_value(t, n.row, 0)

    menu.left(b, &n)
    menu.left(b, &n)
    testing.expect_value(t, n.menu, len(MENUS) - 1)
    menu.right(b, &n)
    testing.expect_value(t, n.menu, 0)
}

// An empty menu is a state, not a crash: stage 3 fills the rows, and a plugin's menu can hold
// nothing. The keys land nowhere, nothing runs, and no box comes up to catch a click.
@(test)
an_empty_menu_has_no_rows_to_land_on :: proc(t: ^testing.T) {
    b := bar()
    n := menu.nav(1) // `edit` holds nothing yet
    menu.down(b, &n)
    _, run := menu.enter(b, &n)
    testing.expect(t, !run, "an empty menu ran something")
    testing.expect_value(t, menu.drop_box(b, n), menu.Box{})
    testing.expect_value(t, menu.hit(b, &n, 28, 2), menu.Hit{.None, -1})
}

// A list taller than the window scrolls, and the selection stays on screen (§4). The box is what
// the window leaves, so the same walk in a short window scrolls and in a tall one does not.
@(test)
a_taller_list_scrolls_and_keeps_the_selection_on_screen :: proc(t: ^testing.T) {
    rows := [6]menu.Row{}
    for &r, i in rows {
        r = {chord = "alt+a", id = i}
    }
    one := [?]menu.Menu{{name = "long", region = .Kernel, rows = rows[:]}}
    b := menu.Bar {
        menus = one[:],
        cols  = 40,
        rows  = 5, // the bar, then a box of four: two borders and two rows
    }

    n := menu.nav(0)
    testing.expect_value(t, menu.drop_box(b, n).h, 4)
    for _ in 0 ..< 3 {
        menu.down(b, &n)
    }
    testing.expect_value(t, n.row, 3)
    testing.expect_value(t, n.top, 2) // moved by the least it can

    menu.up(b, &n)
    testing.expect_value(t, n.top, 2) // still on screen, so the list holds still

    n = menu.nav(0)
    menu.up(b, &n) // wraps to the last row, and the list follows it there
    testing.expect_value(t, n.row, 5)
    testing.expect_value(t, n.top, 4)
}

// §6: a click on the bar or in a dropdown is the menu's and never reaches a panel, and every
// other cell falls through untouched. With nothing up, only the bar's own row answers.
@(test)
a_click_on_the_menu_never_reaches_a_panel :: proc(t: ^testing.T) {
    b := bar()
    testing.expect_value(t, menu.hit(b, nil, 2, 0), menu.Hit{.Name, 0})
    testing.expect_value(t, menu.hit(b, nil, 28, 0), menu.Hit{.Name, CHORDS_MENU})
    testing.expect_value(t, menu.hit(b, nil, 25, 0), menu.Hit{.Frame, -1}) // the separator
    testing.expect_value(t, menu.hit(b, nil, 55, 0), menu.Hit{.Frame, -1}) // past the last name
    testing.expect_value(t, menu.hit(b, nil, 28, 2), menu.Hit{.None, -1}) // no menu is up

    n := menu.nav(CHORDS_MENU)
    testing.expect_value(t, menu.hit(b, &n, 28, 2), menu.Hit{.Row, 0})
    testing.expect_value(t, menu.hit(b, &n, 28, 3), menu.Hit{.Row, 1})
    testing.expect_value(t, menu.hit(b, &n, 27, 3), menu.Hit{.Row, 1}) // its own edge is its line
    testing.expect_value(t, menu.hit(b, &n, 28, 1), menu.Hit{.Frame, -1}) // the box's top border
    testing.expect_value(t, menu.hit(b, &n, 41, 3), menu.Hit{.None, -1}) // beside it: a panel's

    menu.right(b, &n)
    testing.expect_value(t, menu.hit(b, &n, 43, 3), menu.Hit{.Kid, 0})
    testing.expect_value(t, menu.hit(b, &n, 43, 5), menu.Hit{.Kid, 2})
}

package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../gfx"
import "../input"
import "../menu"
import app "../oket"

// MENU.md §4, §5 and §6: the menubar on screen, on keys and under the pointer. The model is
// menubar_test.odin's; what is under test here is the row it reserves (or does not), the six keys
// it claims, the one chord that opens it under a primer, and the cells it takes off the panels.

// One primer, held by a plugin the way a plugin holds one, so `chords` is in the bar. `alt+b` is
// no kernel default, so pressing it arms rather than running.
@(private = "file")
primer_app :: proc() -> (a: app.App, ok: bool) {
    a = bare_app(50, 20) or_return
    app.binds_parse(&a, "[global]\nalt+@AB05 alt+@AC04 = quit\n", "binds.conf")
    return a, true
}

@(private = "file")
open_menu :: proc(a: ^app.App) -> (input.Pending_Menu, bool) {
    p, up := a.pending.(input.Pending_Menu)
    return p, up
}

// Which menu the keys are on, by name, so a test says `chords` rather than an index that moves
// when a plugin loads.
@(private = "file")
menu_name :: proc(a: ^app.App, n: menu.Nav) -> string {
    b := app.menubar_frame(a)
    return n.menu >= 0 && n.menu < len(b.menus) ? b.menus[n.menu].name : ""
}

// How many `down` keys reach the first row of `name` whose own name starts with `want`.
@(private = "file")
rows_down :: proc(a: ^app.App, name, want: string) -> (int, bool) {
    b := app.menubar_frame(a)
    for m in b.menus {
        if m.name != name {
            continue
        }
        for r, i in m.rows {
            if strings.has_prefix(r.name, want) {
                return i, true
            }
        }
    }
    return 0, false
}

// §5's table, in one pass: space opens the menu, and what is HELD when you press it says where.
// The help chord mirrors the primer's own modifier, so `alt+b` reserves `alt+space` and nothing
// else — `ctrl+space` under it is an ordinary unclaimed chord.
@(test)
space_opens_the_menu_and_the_primer_says_where :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)

    // No primer: the first menu, and no popout.
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    p, up := open_menu(&a)
    testing.expect(t, up, "alt+space opened no menu")
    testing.expect_value(t, menu_name(&a, a.menu_nav), "file")
    testing.expect(t, !menu.popped(a.menu_nav), "a popout with no primer behind it")
    testing.expect_value(t, p.prefix, input.Chord{}) // no primer behind it, so no prefix on it
    input.pending_set(&a.pending)

    // Under the primer: the same key with the primer's modifier, and it lands on that primer's
    // own popout rather than on the first menu.
    app.handle_chord(&a, chord("AB05", {.Alt}))
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    p, up = open_menu(&a)
    testing.expect(t, up, "alt+space under a primer opened no menu")
    testing.expect_value(t, menu_name(&a, a.menu_nav), "chords")
    testing.expect(t, menu.popped(a.menu_nav), "the primer's children are not out")
    testing.expect_value(t, p.prefix, chord("AB05", {.Alt}))
    input.pending_set(&a.pending)

    // A DIFFERENT modifier is not this primer's help chord: it is a modified chord no child
    // claims, so it is absorbed and reported the way §4.2 says.
    app.handle_chord(&a, chord("AB05", {.Alt}))
    app.handle_chord(&a, chord("SPCE", {.Ctrl}))
    _, wrong := open_menu(&a)
    testing.expect(t, !wrong, "ctrl+space opened another primer's menu")
    testing.expect(t, strings.contains(a.message, "unbound"), a.message)
}

// The comparison IGNORES `Chord.held`. Keeping `b` down through `alt+b` into `alt+space` is the
// natural way to type this, and the second chord then arrives qualified by `b` — an equality test
// against a zero `held` would miss the chord the user actually typed.
@(test)
the_help_chord_arrives_with_the_primers_key_still_down :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("AB05", {.Alt}))
    app.handle_chord(&a, chord("SPCE", {.Alt}, held = "AB05"))
    _, up := open_menu(&a)
    testing.expect(t, up, "a held key hid the help chord")
    testing.expect_value(t, menu_name(&a, a.menu_nav), "chords")
    testing.expect(t, menu.popped(a.menu_nav))
}

// The menu claims six keys and nothing else (§5). Anything else falls THROUGH and closes, in the
// one keystroke: f1 opens describe and the menu is gone, both from one press.
@(test)
an_unclaimed_chord_runs_and_closes_the_menu :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("SPCE", {.Alt}))
    _, up := open_menu(&a)
    testing.expect(t, up)

    app.handle_chord(&a, chord("FK01"))
    _, still := open_menu(&a)
    testing.expect(t, !still, "the menu swallowed a chord it does not claim")
    _, describing := a.pending.(input.Pending_Describe)
    testing.expect(t, describing, "f1 did not reach its own row")
}

// `enter` runs a chord row and STAGES a `:` row, which is what a `stage` bind already does: the
// `<arg>` holes stay visible and editable before anything commits.
@(test)
enter_runs_a_bind_row_and_stages_a_builtin :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)

    down, found := rows_down(&a, "file", ":open")
    testing.expect(t, found, "the file menu names no :open")
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    for _ in 0 ..< down {
        app.handle_chord(&a, chord("DOWN"))
    }
    app.handle_chord(&a, chord("RTRN"))
    testing.expect(t, app.cl_active(&a), "enter on a builtin opened no command line")
    testing.expect(t, strings.contains(app.cl_line(&a), "<path>"), app.cl_line(&a))
    app.cl_hide(&a)

    // And a bind row does what its chord does. `file.quit` is one press from the same menu.
    down, found = rows_down(&a, "file", "file.quit")
    testing.expect(t, found, "the file menu names no file.quit")
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    for _ in 0 ..< down {
        app.handle_chord(&a, chord("DOWN"))
    }
    app.handle_chord(&a, chord("RTRN"))
    testing.expect(t, a.pending == nil, "the menu stayed up over the row it ran")
    testing.expect(t, a.quit, "enter on a bind row ran nothing")
}

// Escape closes the popout, then the menu: two presses from a primer's children, and the keys
// are back where they were with nothing else touched.
@(test)
escape_closes_the_popout_then_the_menu :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("AB05", {.Alt}))
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    app.handle_chord(&a, chord("ESC"))
    _, up := open_menu(&a)
    testing.expect(t, up, "escape closed the menu and the popout at once")
    testing.expect(t, !menu.popped(a.menu_nav), "the popout stayed out")

    app.handle_chord(&a, chord("ESC"))
    _, still := open_menu(&a)
    testing.expect(t, !still, "escape left the menu up")
    testing.expect(t, !a.quit, "escape fell through to quit")
}

// §4: hidden costs the panels nothing. Opening it reflows no document and sends no winsize —
// the size a session is resized to IS the panel's body (term.odin), so a body that did not move
// is a winsize that was not sent.
@(test)
opening_a_hidden_menu_reflows_nothing :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "a.txt", "hello"))
    app.surface_draw(&a)

    was := app.panel_focused(&a).body
    rows := app.panel_focused(&a).grid.rows
    testing.expect_value(t, app.menu_show(&a), app.Menu_Show.Hidden)
    testing.expect_value(t, was.h, 19) // twenty rows, less the command line's

    app.handle_chord(&a, chord("SPCE", {.Alt}))
    app.surface_draw(&a)
    testing.expect_value(t, app.panel_focused(&a).body, was)
    testing.expect_value(t, app.panel_focused(&a).grid.rows, rows)

    // The bar is drawn anyway, over the top row of whatever is there: its own grid, so nothing
    // under it moved to make space.
    testing.expect(t, a.menu[.Bar].on, "no bar was drawn for an open menu")
    testing.expect(t, a.menu[.Drop].on, "no dropdown was drawn for an open menu")
    text := gfx.grid_snapshot(&a.menu[.Bar].grid)
    defer delete(text)
    testing.expect_value(t, text, " file  edit  view  panel │ chords")
}

// The same app with a config.conf beside it. `[menu] show = constant` is the one mode where the
// bar is on screen with no menu up, so it is the mode a click on the bar is asked about.
@(private = "file")
config_app :: proc(t: ^testing.T, name, body: string) -> (a: app.App, dir: string, ok: bool) {
    dir = scratch(t, name) or_return
    a = primer_app() or_return
    path, _ := filepath.join({dir, app.CONFIG_NAME}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(path, transmute([]u8)body) == nil)
    app.home_set(&a.home, dir) // owned by the App, and freed before close_app
    app.config_load(&a)
    app.surface_fit(&a, 50, 20)
    return a, dir, true
}

@(private = "file")
constant_app :: proc(t: ^testing.T, name: string) -> (app.App, string, bool) {
    return config_app(t, name, "[menu]\nshow = constant\n")
}

// And `constant` costs them exactly one row, at the FIT and not at the open: the reflow is the
// start's, and opening the menu is still free.
@(test)
a_constant_menubar_costs_one_row_at_the_start :: proc(t: ^testing.T) {
    a, dir, ok := constant_app(t, "oket-menubar-constant")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)
    defer app.home_destroy(&a.home)

    testing.expect_value(t, app.menu_show(&a), app.Menu_Show.Constant)
    was := app.panel_focused(&a).body
    testing.expect_value(t, was.h, 18) // one for the command line, one for the bar

    app.handle_chord(&a, chord("SPCE", {.Alt}))
    app.surface_draw(&a)
    testing.expect_value(t, app.panel_focused(&a).body, was)

    // The bar is on the reserved row whether a menu is up or not, which is the one difference
    // between the two modes.
    input.pending_set(&a.pending)
    app.surface_draw(&a)
    testing.expect(t, a.menu[.Bar].on, "a constant bar went away with the menu")
    testing.expect(t, !a.menu[.Drop].on, "a dropdown with no menu up")
    testing.expect_value(t, a.menu[.Bar].at, [2]int{0, 0})
}

// --- the mouse (§6) ---

// A press, in cells: a test has no painter and bare_app leaves the cell one pixel, so a pixel IS
// a cell here. True is the menu having taken it, which is where button_callback returns — before
// the focus, the point and the chord a panel would have had.
@(private = "file")
press :: proc(a: ^app.App, x, y: int) -> bool {
    pn, cx, cy := app.panel_hit(a, x, y)
    return app.menu_took_button(a, pn, cx, cy, true)
}

// Where a menu's name sits on the bar, and where the row `i` of what it drops sits under it.
@(private = "file")
name_at :: proc(a: ^app.App, want: string) -> (x: int, ok: bool) {
    b := app.menubar_frame(a)
    for m, i in b.menus {
        if m.name == want {
            x, _ = menu.name_span(b, i)
            return x, true
        }
    }
    return 0, false
}

@(private = "file")
row_at :: proc(a: ^app.App, i: int) -> (x, y: int) {
    box := menu.drop_box(app.menubar_frame(a), a.menu_nav)
    return box.x + 1, box.y + 1 + i - a.menu_nav.top
}

@(private = "file")
kid_at :: proc(a: ^app.App, i: int) -> (x, y: int) {
    box := menu.kid_box(app.menubar_frame(a), a.menu_nav)
    return box.x + 1, box.y + 1 + i - a.menu_nav.ktop
}

// The bar's own row is the MENU'S cell and not the panel's under it, so a click on it opens a
// menu and the document below never hears about it. The name that opened it closes it.
@(test)
a_click_on_the_bar_opens_a_menu_and_moves_no_caret :: proc(t: ^testing.T) {
    a, dir, ok := constant_app(t, "oket-menubar-click")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)
    defer app.home_destroy(&a.home)
    app.ring_add(&a, scratch_doc(&a, "a.txt", "hello\nworld"))
    app.surface_draw(&a)

    was := point(&a)
    x, found := name_at(&a, "file")
    testing.expect(t, found, "no file menu on the bar")
    pn, _, _ := app.panel_hit(&a, x, 0)
    testing.expect_value(t, pn, app.PANEL_MENU)

    testing.expect(t, press(&a, x, 0), "the bar's own row did not take the press")
    _, up := open_menu(&a)
    testing.expect(t, up, "a click on the bar opened no menu")
    testing.expect_value(t, menu_name(&a, a.menu_nav), "file")
    testing.expect_value(t, point(&a), was)

    // The same name again: what opened it closes it, which is the one thing a name does twice.
    testing.expect(t, press(&a, x, 0))
    _, still := open_menu(&a)
    testing.expect(t, !still, "the name that opened the menu left it up")

    // The reserved row pushes the hit down with the panels: window row 1 is the document's row 0.
    bpn, _, brow := app.panel_hit(&a, 2, 1)
    testing.expect_value(t, bpn, 0)
    testing.expect_value(t, brow, 0)
}

// A row does what typing it does, and a primer's row pops its children out for a second click.
// The nav is the one state both work, so the keys pick up where the pointer left them.
@(test)
a_click_runs_a_row_and_pops_a_primer_out :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)

    // Opened by the key, then steered by the pointer: the bar is the menu's row while one is up,
    // hidden or not.
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    x, found := name_at(&a, "chords")
    testing.expect(t, found, "no chords menu with a primer in the table")
    testing.expect(t, press(&a, x, 0))
    testing.expect_value(t, menu_name(&a, a.menu_nav), "chords")

    rx, ry := row_at(&a, 0)
    testing.expect(t, press(&a, rx, ry), "the dropdown did not take the press")
    testing.expect(t, menu.popped(a.menu_nav), "a click on a primer row popped nothing out")
    testing.expect(t, !a.quit, "a primer row ran a verb")

    kx, ky := kid_at(&a, 0)
    testing.expect(t, press(&a, kx, ky), "the popout did not take the press")
    testing.expect(t, a.pending == nil, "the menu stayed up over the row it ran")
    testing.expect(t, a.quit, "a click on a child ran nothing")
}

@(private = "file")
hover :: proc(a: ^app.App, x, y: int) {
    pn, cx, cy := app.panel_hit(a, x, y)
    app.menu_hover(a, pn, cx, cy)
}

// The pointer moves the same nav the keys move, so the arrows carry on from the row it left. It
// opens nothing: a name it passes over with no menu up stays shut, and a primer it passes over
// keeps its children in.
@(test)
the_pointer_moves_the_selection_it_passes_over :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)

    // Nothing is up, so nothing follows the pointer: hidden draws no bar to pass over.
    x, _ := name_at(&a, "file")
    hover(&a, x, 0)
    _, up := open_menu(&a)
    testing.expect(t, !up, "hovering the bar opened a menu")

    app.handle_chord(&a, chord("SPCE", {.Alt}))
    rx, ry := row_at(&a, 2)
    hover(&a, rx, ry)
    testing.expect_value(t, a.menu_nav.row, 2)

    // And the keys carry on from there, because it is the one nav.
    app.handle_chord(&a, chord("DOWN"))
    testing.expect_value(t, a.menu_nav.row, 3)

    // Across the bar: a name under the pointer with a menu already up switches to it.
    cx, found := name_at(&a, "chords")
    testing.expect(t, found)
    hover(&a, cx, 0)
    testing.expect_value(t, menu_name(&a, a.menu_nav), "chords")
    testing.expect_value(t, a.menu_nav.row, 0)
    testing.expect(t, !menu.popped(a.menu_nav), "the pointer popped a primer out")

    // A popout the pointer has to CROSS its own parent row to reach stays out on the way.
    prx, pry := row_at(&a, 0)
    testing.expect(t, press(&a, prx, pry))
    hover(&a, prx, pry)
    testing.expect(t, menu.popped(a.menu_nav), "crossing the parent row shut its popout")

    kx, ky := kid_at(&a, 0)
    hover(&a, kx, ky)
    testing.expect_value(t, a.menu_nav.kid, 0)
    testing.expect(t, !a.quit, "the pointer ran a row it only passed over")
}

// The other half of §6: a press anywhere else closes the menu and does nothing further. It
// returns TAKEN, which is where button_callback stops — so no focus moves, no point is placed
// and no chord is dispatched for the click that shut it.
@(test)
a_click_behind_an_open_menu_closes_it_and_places_nothing :: proc(t: ^testing.T) {
    a, ok := primer_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "a.txt", "hello\nworld"))
    app.surface_draw(&a)

    // Hidden keeps no row, so with nothing up the top row is the document's own.
    pn, _, y := app.panel_hit(&a, 2, 0)
    testing.expect_value(t, pn, 0)
    testing.expect_value(t, y, 0)
    testing.expect(t, !press(&a, 2, 0), "the menu took a press with nothing drawn")

    // Up, and the bar is drawn over that same row: the cell is the menu's now. Opened under the
    // primer, so what drops is the one narrow list and the panel keeps its left edge.
    app.handle_chord(&a, chord("AB05", {.Alt}))
    app.handle_chord(&a, chord("SPCE", {.Alt}))
    was := point(&a)
    pn, _, _ = app.panel_hit(&a, 2, 0)
    testing.expect_value(t, pn, app.PANEL_MENU)

    // And a cell no part of the menu holds shuts it, with the document untouched.
    pn, _, _ = app.panel_hit(&a, 1, 17)
    testing.expect_value(t, pn, 0)
    testing.expect(t, press(&a, 1, 17), "a press behind the menu was left to the panel")
    _, still := open_menu(&a)
    testing.expect(t, !still, "a press behind the menu left it up")
    testing.expect_value(t, point(&a), was)
}

// §4's palette. The bar sits ON the screen rather than in it, so with nothing said it takes the
// theme the OTHER way round: a dark theme draws a light bar. `light` swaps the ground and the
// ink and darkens the two mid tones; no theme grows a token for it.
@(test)
the_menubar_takes_the_theme_the_other_way_round :: proc(t: ^testing.T) {
    a, dir, ok := config_app(t, "oket-menubar-palette", "[menu]\npalette = dark\n")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)
    defer app.home_destroy(&a.home)

    // Said outright: the bar is drawn like every document, and nothing is derived.
    testing.expect_value(t, app.menu_palette(&a), app.Menu_Palette.Dark)
    testing.expect_value(t, app.menu_theme(&a), a.theme)

    // The default, against the default theme, which is a dark one. A file that says nothing is
    // the config with no rows in it.
    app.config_destroy(&a.config)
    testing.expect_value(t, app.menu_palette(&a), app.Menu_Palette.Invert)
    th := app.menu_theme(&a)
    testing.expect_value(t, th[.Bg], a.theme[.Fg]) // the ground is the ink
    testing.expect_value(t, th[.Fg], a.theme[.Bg])
    // The ladder off the cream ground, the same way round as it reads off a dark one: the ink
    // first, then what stands out, then what recedes.
    testing.expect(t, luma(th[.Fg]) < luma(th[.Accent]), "the accent is darker than the ink")
    testing.expect(t, luma(th[.Accent]) < luma(th[.Dim]), "the accent does not stand out")
    testing.expect(t, luma(th[.Dim]) < luma(th[.Bg]), "a mid tone is lighter than its ground")

    // And the other way: a light theme inverts to a dark bar, which is the same rule. The mid
    // tones are back on the dark ground they were picked for, so nothing is shaded.
    a.theme[.Fg], a.theme[.Bg] = a.theme[.Bg], a.theme[.Fg]
    th = app.menu_theme(&a)
    testing.expect_value(t, th[.Bg], a.theme[.Fg])
    testing.expect_value(t, th[.Fg], a.theme[.Bg])
    testing.expect_value(t, th[.Accent], a.theme[.Accent])
    testing.expect_value(t, th[.Dim], a.theme[.Dim])
}

@(private = "file")
luma :: proc(c: [3]f32) -> f32 {
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
}

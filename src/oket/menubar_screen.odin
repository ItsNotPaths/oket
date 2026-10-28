package main

import "../gfx"
import "../input"
import "../menu"
import "../menubar"

// The menubar screen's host (src/menubar/screen.odin): the window's geometry, the config's two
// rows, and what an Act does here. The Pending_Menu in `pending` is the one thing that says a
// menu is up — no flag anywhere.

// Named here because App's own `menu` field hides the package inside the struct.
Menu_Screen :: menubar.Screen

menu_show :: proc(a: ^App) -> menubar.Show {
    return menubar.show_named(menu_config(a, "show"))
}

menu_palette :: proc(a: ^App) -> menubar.Palette {
    return menubar.palette_named(menu_config(a, "palette"))
}

menu_theme :: proc(a: ^App) -> gfx.Theme {
    return menubar.theme(a.theme, menu_palette(a))
}

@(private = "file")
menu_config :: proc(a: ^App, key: string) -> string {
    named := config_names(&a.config, MENU_SECTION, key)
    return len(named) > 0 ? named[0] : ""
}

// The rows the bar keeps for itself, which is the whole of what `constant` costs: one offset in
// panels_fit, one in the paint, one in the hit test.
menu_rows :: proc(a: ^App) -> int {
    return menu_show(a) == .Constant ? 1 : 0
}

@(private = "file")
menu_up :: proc(a: ^App) -> bool {
    _, up := a.pending.(input.Pending_Menu)
    return up
}

// The bar the frame draws: the model, with the window's geometry on it. `rows` is what a list
// may fill, and the command line's row is not part of it — the same rule panels_fit follows
// for a panel.
menubar_frame :: proc(a: ^App, allocator := context.temp_allocator) -> menu.Bar {
    b := menubar_build(a, allocator)
    b.y = 0 // either way: constant reserves the row, hidden draws over whatever is on it
    // The width CEILS over the window, so a name can clip on its last glyph (§11). What a
    // list may fill is the menubar's own rows plus the strip's (frame.odin).
    b.cols = frame_cover(f32(a.win.x), a.cell.x)
    b.rows = a.frame.menu + a.frame.body.h
    b.cell = {f32(a.cell.x), f32(a.cell.y)}
    return b
}

// Filled after the panels are drawn and painted after they are. A hidden bar exists only while
// the menu is up; a constant one is always on the reserved row.
menubar_draw :: proc(a: ^App) {
    up := menu_up(a)
    if !up && menu_show(a) != .Constant {
        menubar.hide(&a.menu)
        return
    }
    menubar.draw(&a.menu, menubar_frame(a), menu_theme(a), up)
}

// Over the panels, because a menu a panel covers is a menu nobody can read.
menubar_paint :: proc(a: ^App, win_w, win_h: i32) {
    menubar.paint(&a.menu, &a.painter, win_w, win_h)
}

menubar_destroy :: proc(a: ^App) {
    menubar.destroy(&a.menu)
}

// `menu.open`, and what a primer's help chord opens: the bar on its first menu, or on that
// primer's own popout.
menu_open :: proc(a: ^App, prefix := input.Chord{}) {
    primer := prefix == {} ? "" : input.chord_format(prefix, key_layout_name, context.temp_allocator)
    menubar.open(&a.menu, menubar_frame(a), primer)
    input.pending_set(&a.pending, input.Pending_Menu{prefix})
}

// A chord the menu does not claim closes it and is still resolved under the primer it opened
// on, if any: the menu is a rendering of that primer's children and the chord was typed at them.
menu_take :: proc(a: ^App, chord: input.Chord) -> bool {
    p, _ := a.pending.(input.Pending_Menu)
    act, row := menubar.take(&a.menu, menubar_frame(a), chord)
    menu_act(a, act, row)
    return act != .Fall || prefix_resolve(a, chord, p.prefix)
}

// Which PIXEL of the window the menu holds, asked before the strip is (panel_hit). Nothing is
// drawn when the bar is hidden and no menu is up, so nothing is hit; a shut bar holds row 0.
// Both are answered before the bar is BUILT, because this runs on every pointer motion.
menu_hit :: proc(a: ^App, px, py: int) -> (menu.Hit, bool) {
    up := menu_up(a)
    if !up && (menu_show(a) == .Hidden || py < 0 || py >= a.cell.y) {
        return {}, false
    }
    nav: ^menu.Nav = up ? &a.menu.nav : nil
    h := menu.hit(menubar_frame(a), nav, f32(px), f32(py))
    return h, h.part != .None
}

// The menu's share of a button event, taken before the panels get any of it (§6). A press ON the
// menu works it; a press anywhere else with one up closes it and does nothing further — no
// focus, no point and no chord. A key says what it wants and still means it; a click outside a
// menu is aimed at the menu.
menu_took_button :: proc(a: ^App, pn, x, y: int, press: bool) -> bool {
    if pn == PANEL_MENU {
        // Neither half reaches the panel under it, so a press waiting on its release is dropped:
        // a release the menu ate is a click that never happened.
        input.mouse_drop(&a.mouse)
        if !press {
            return true
        }
        if h, on := menu_hit(a, x, y); on {
            act, row := menubar.click(&a.menu, menubar_frame(a), h, menu_up(a))
            menu_act(a, act, row)
        }
        return true
    }
    if press && menu_up(a) {
        input.pending_set(&a.pending)
        return true
    }
    return false
}

menu_hover :: proc(a: ^App, pn, x, y: int) {
    if !menu_up(a) || pn != PANEL_MENU {
        return
    }
    if h, on := menu_hit(a, x, y); on {
        menubar.hover(&a.menu, h)
    }
}

@(private = "file")
menu_act :: proc(a: ^App, act: menubar.Act, row: menu.Row) {
    switch act {
    case .None:
    case .Open:
        // Under no primer: a chord that falls through a menu the pointer opened resolves
        // against nothing.
        input.pending_set(&a.pending, input.Pending_Menu{})
    case .Close, .Fall:
        input.pending_set(&a.pending)
    case .Run:
        input.pending_set(&a.pending) // shut before it runs: the row may open the command line
        menu_run(a, row)
    }
}

// Pressing a row does what typing it does (§1). A `:` row IS its own line, holes and all, so it
// is staged the way a `:stage` bind row is; a bind row goes down the path its chord goes down.
@(private = "file")
menu_run :: proc(a: ^App, row: menu.Row) {
    if row.id == menubar.STAGE {
        cl_show(a, row.name)
        return
    }
    b := a.binds[row.id]
    bind_dispatch(a, b.chord, b)
}

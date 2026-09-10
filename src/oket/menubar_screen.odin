package main

import "../gfx"
import "../input"
import "../menu"

// The menubar on screen, on keys and under the pointer (MENU.md §4-§6): the interaction layer
// over the model menubar.odin builds. It never walks a table itself — every row it draws, runs
// or hits came out of menubar_build, so where a row came from is not its business.

// --- on screen (§4) ---

// `[menu] show`. Hidden costs the panels nothing and draws over the top row of whatever is
// there; constant fits them one row shorter and always paints the bar. One draw path either
// way: the two differ in that reserved row and in nothing else.
Menu_Show :: enum u8 {
    Hidden,
    Constant,
}

// Three grids and no more (MENU.md §4): a popout hangs off a dropdown row and never off another
// popout, so there is nothing to draw at a fourth level.
Menu_Part :: enum u8 {
    Bar,
    Drop,
    Kid,
}

Menu_Layer :: struct {
    grid: gfx.Grid,
    at:   [2]int, // the ground's cells, which is what the frame turns into pixels
    on:   bool,
}

// App's `menu` field shadows the package inside the struct body, so the nav field is typed
// through this alias and app.odin needs no view of `src/menu`.
Menu_Nav :: menu.Nav

// `[menu] palette` (§4). The bar reads as a thing sitting ON the screen rather than one more
// panel, so the default takes the theme the OTHER way round from every document. `dark` and
// `light` say which way round instead of asking.
Menu_Palette :: enum u8 {
    Invert,
    Dark,
    Light,
}

// The two mid tones were both picked to read on the DARK ground, and neither survives a cream
// one: gruvbox's `Accent` on gruvbox's `Fg` is under 2:1. Darkened until the ladder from the
// ground reads the same way round as it does in the dark — ink, then accent, then dim — so the
// accent still stands out and the dim still recedes.
MENU_SHADE_ACCENT :: 70
MENU_SHADE_DIM :: 35

menu_palette :: proc(a: ^App) -> Menu_Palette {
    named := config_names(&a.config, MENU_SECTION, "palette")
    if len(named) == 0 {
        return .Invert
    }
    switch named[0] {
    case "dark":
        return .Dark
    case "light":
        return .Light
    }
    return .Invert // a value nobody recognises is the one the file did not have to say
}

// The theme the three grids are HANDED, which is what keeps `src/menu` from ever learning which
// way round it is drawn — the rule `bar_theme` already follows for the command line's row. A
// theme already the way round asked for passes through; the other way round swaps the ground
// and the ink, and a swap ONTO the light ground darkens the two mid tones with it.
menu_theme :: proc(a: ^App) -> gfx.Theme {
    light := menu_light(a)
    if light != gfx.theme_dark(a.theme) {
        return a.theme
    }
    th := a.theme
    th[.Fg], th[.Bg] = a.theme[.Bg], a.theme[.Fg]
    if light {
        th[.Accent] = gfx.shade(a.theme[.Accent], MENU_SHADE_ACCENT)
        th[.Dim] = gfx.shade(a.theme[.Dim], MENU_SHADE_DIM)
    }
    return th
}

@(private = "file")
menu_light :: proc(a: ^App) -> bool {
    switch menu_palette(a) {
    case .Dark:
        return false
    case .Light:
        return true
    case .Invert:
        return gfx.theme_dark(a.theme)
    }
    return false
}

// A value nobody recognises reads as hidden, which is the one the file did not have to say —
// the rule `[cursor] split` already follows.
menu_show :: proc(a: ^App) -> Menu_Show {
    named := config_names(&a.config, MENU_SECTION, "show")
    return len(named) > 0 && named[0] == "constant" ? .Constant : .Hidden
}

// The rows the bar keeps for itself, which is the whole of what `constant` costs: one offset in
// panels_fit, one in the paint, one in the hit test.
menu_rows :: proc(a: ^App) -> int {
    return menu_show(a) == .Constant ? 1 : 0
}

// The bar the frame draws: the model, with the window's geometry on it. `rows` is what a list
// may fill, and the command line's row is not part of it — the same rule panels_fit follows
// for a panel.
menubar_frame :: proc(a: ^App, allocator := context.temp_allocator) -> menu.Bar {
    b := menubar_build(a, allocator)
    b.y = 0 // either way: constant reserves the row, hidden draws over whatever is on it
    // Everything but the bar's row, and read off the frame rather than counted here: what a
    // list may fill is the menubar's own rows plus the strip's (frame.odin).
    b.cols, b.rows = a.frame.bar.w, a.frame.menu.h + a.frame.body.h
    return b
}

// The three grids, filled after the panels are drawn and painted after they are. A hidden bar
// exists only while the menu is up; a constant one is always on the reserved row.
menubar_draw :: proc(a: ^App) {
    for &l in a.menu {
        l.on = false
    }
    _, up := a.pending.(input.Pending_Menu)
    reserved := menu_show(a) == .Constant
    if !up && !reserved {
        return
    }
    b := menubar_frame(a)
    nav: ^menu.Nav = up ? &a.menu_nav : nil
    menu_layer(a, .Bar, {0, b.y, b.cols, 1})
    th := menu_theme(a)
    // A reserved row has a frame box under it and nothing reaches it. A hidden bar FLOATS over
    // a document, and a transparent one would read the text it covers through itself.
    ground := reserved ? gfx.NOTHING : gfx.opaque(th[.Bg])
    menu.draw_bar(b, &a.menu[.Bar].grid, th, ground, nav)
    if !up {
        return
    }
    if box := menu.drop_box(b, a.menu_nav); menu.has_room(box) {
        menu_layer(a, .Drop, box)
        menu.draw_drop(b, a.menu_nav, &a.menu[.Drop].grid, th)
    }
    if box := menu.kid_box(b, a.menu_nav); menu.has_room(box) {
        menu_layer(a, .Kid, box)
        menu.draw_kids(b, a.menu_nav, &a.menu[.Kid].grid, th)
    }
}

@(private = "file")
menu_layer :: proc(a: ^App, part: Menu_Part, box: menu.Box) {
    l := &a.menu[part]
    gfx.grid_resize(&l.grid, box.w, box.h)
    l.at, l.on = {box.x, box.y}, true
}

// Over the panels, because a menu a panel covers is a menu nobody can read. The origin is the
// ground's corner plus the box's own cells; nothing here slides, so there is no camera in it.
menubar_paint :: proc(a: ^App, win_w, win_h: i32) {
    p := &a.painter
    ox, oy := gfx.painter_origin(p, win_w, win_h, a.ground.cols, a.ground.rows)
    cw, ch := gfx.painter_cell(p)
    for &l in a.menu {
        if !l.on {
            continue
        }
        x, y := i32(ox + l.at.x * cw), i32(oy + l.at.y * ch)
        gfx.painter_draw(p, &l.grid, win_w, win_h, {f32(x), f32(y)},
                         {x, y, i32(l.grid.cols * cw), i32(l.grid.rows * ch)})
    }
}

menubar_destroy :: proc(a: ^App) {
    for &l in a.menu {
        gfx.grid_destroy(&l.grid)
    }
}

// --- and on keys (§5) ---

// `menu.open`, and what a primer's help chord opens: the bar on its first menu, or on that
// primer's own popout. The Pending_Menu this sets is the one thing that says a menu is up — no
// flag anywhere — and the nav beside the grids is reset here, so a stale one cannot leak into a
// fresh open. A primer with no row to open on — nothing in the table primes it any more —
// still opens the bar, because the keystroke asked for a menu.
menu_open :: proc(a: ^App, prefix := input.Chord{}) {
    b := menubar_frame(a)
    a.menu_nav = menu.nav(0)
    if at, row, found := menubar_primer_at(a, b, prefix); found {
        a.menu_nav = menu.nav(at)
        // Walked rather than set, so the scroll follows the row the way it does for a key.
        for _ in 0 ..< row {
            menu.down(b, &a.menu_nav)
        }
        menu.right(b, &a.menu_nav) // the popout, which is what the chord was asking for
    }
    input.pending_set(&a.pending, input.Pending_Menu{prefix})
}

// Where a primer sits in the bar: the `chords` menu, and the row that spells that chord. Matched
// on the SPELLING, because that is all a row carries — four strings and an opaque id (§7).
@(private = "file")
menubar_primer_at :: proc(a: ^App, b: menu.Bar, prefix: input.Chord) -> (at, row: int, ok: bool) {
    if prefix == (input.Chord{}) {
        return 0, 0, false
    }
    want := input.chord_format(prefix, key_layout_name, context.temp_allocator)
    for m, i in b.menus {
        if m.name != MENU_CHORDS {
            continue
        }
        for r, j in m.rows {
            if r.chord == want {
                return i, j, true
            }
        }
    }
    return 0, 0, false
}

// The six keys, and nothing else. Anything the menu does not claim falls THROUGH and closes in
// the one keystroke, which is the whole difference between this and a mode: a chord that does
// something keeps doing it.
menu_take :: proc(a: ^App, chord: input.Chord) -> bool {
    p, _ := a.pending.(input.Pending_Menu)
    b := menubar_frame(a)
    switch {
    case menu_key(chord, "LEFT"):
        menu.left(b, &a.menu_nav)
    case menu_key(chord, "RGHT"):
        menu.right(b, &a.menu_nav)
    case menu_key(chord, "UP"):
        menu.up(b, &a.menu_nav)
    case menu_key(chord, "DOWN"):
        menu.down(b, &a.menu_nav)
    case menu_key(chord, "RTRN"):
        menu_enter(a, b)
    case menu_key(chord, "ESC"):
        if menu.esc(&a.menu_nav) {
            input.pending_set(&a.pending)
        }
    case:
        // Still under the primer this opened on, if it opened on one: the menu is a rendering of
        // that primer's children and the chord was typed at them.
        input.pending_set(&a.pending)
        return prefix_resolve(a, chord, p.prefix)
    }
    return true
}

// What `enter` does, whether a key or a click asked for it: a primer's row pops its children out
// and runs nothing, and every other row runs and closes. The row is read BEFORE the nav moves,
// because that is the row being run.
@(private = "file")
menu_enter :: proc(a: ^App, b: menu.Bar) {
    row, _ := menu.selected(b, a.menu_nav)
    if _, run := menu.enter(b, &a.menu_nav); !run {
        return // a primer, and its children are out now
    }
    input.pending_set(&a.pending) // shut before it runs: the row may open the command line
    menu_run(a, row)
}

// A claimed key is the bare key: `alt+left` is `panel.prev` and falls through, and `tab+enter` is
// the picker's chord and is not the menu's enter.
@(private = "file")
menu_key :: proc(chord: input.Chord, name: string) -> bool {
    code, _ := input.key_code(name)
    return chord == input.Chord{code, {}, 0}
}

// --- and on the mouse (§6) ---

// Which cell of the window the menu holds, asked before the strip is (panel_hit). Nothing is
// drawn when the bar is hidden and no menu is up, so nothing is hit; a shut bar holds row 0,
// which is menubar_frame's `y` in both modes. Both are answered before the bar is BUILT, because
// this runs on every pointer motion.
menu_hit :: proc(a: ^App, x, y: int) -> (menu.Hit, bool) {
    _, up := a.pending.(input.Pending_Menu)
    if !up && (menu_show(a) == .Hidden || y != 0) {
        return {}, false
    }
    b := menubar_frame(a)
    nav: ^menu.Nav = up ? &a.menu_nav : nil
    h := menu.hit(b, nav, x, y)
    return h, h.part != .None
}

// The menu's share of a button event, taken before the panels get any of it (§6). A press ON the
// menu works it; a press anywhere else with one up closes it and does nothing further — no
// focus, no point and no chord. That is the mouse's whole fall-through, and it differs from a
// key's on purpose: a key says what it wants and still means it, a click outside a menu is aimed
// at the menu.
menu_took_button :: proc(a: ^App, pn, x, y: int, press: bool) -> bool {
    if pn == PANEL_MENU {
        // Neither half reaches the panel under it, so a press waiting on its release is dropped:
        // a release the menu ate is a click that never happened.
        input.mouse_drop(&a.mouse)
        if press {
            menu_click(a, x, y)
        }
        return true
    }
    if _, up := a.pending.(input.Pending_Menu); press && up {
        input.pending_set(&a.pending)
        return true
    }
    return false
}

// The pointer moves the SAME nav the keys move, so the arrows carry on from the row it left. It
// opens nothing and pops nothing out: passing over a name or a primer must not arm what a press
// is for.
menu_hover :: proc(a: ^App, pn, x, y: int) {
    _, up := a.pending.(input.Pending_Menu)
    if !up || pn != PANEL_MENU {
        return
    }
    h, on := menu_hit(a, x, y)
    if !on {
        return
    }
    n := &a.menu_nav
    switch h.part {
    case .None, .Frame:
    case .Name:
        if n.menu != h.i {
            n^ = menu.nav(h.i) // a different list, so its own row and its own scroll
        }
    case .Row:
        if h.i != n.row {
            // The row a popout hangs off keeps it while the pointer crosses that row to reach
            // it; any other row is a new selection and shuts it.
            n.row, n.kid = h.i, -1
        }
    case .Kid:
        n.kid = h.i
    }
}

// A press on the menu: a name opens that menu and the open one's name closes it, a row runs the
// way `enter` runs it, and a border is the menu's too and does nothing. The keys pick up where
// the pointer left them, because the nav is the one state either works.
menu_click :: proc(a: ^App, x, y: int) {
    h, on := menu_hit(a, x, y)
    if !on {
        return
    }
    b := menubar_frame(a)
    _, up := a.pending.(input.Pending_Menu)
    switch h.part {
    case .None, .Frame:
    case .Name:
        if up && a.menu_nav.menu == h.i && !menu.popped(a.menu_nav) {
            input.pending_set(&a.pending) // the name that opened it closes it
            return
        }
        // No prefix: a menu the pointer opened is under no primer, so a chord that falls
        // through it resolves against nothing.
        a.menu_nav = menu.nav(h.i)
        input.pending_set(&a.pending, input.Pending_Menu{})
    case .Row:
        if !up {
            return
        }
        a.menu_nav.row, a.menu_nav.kid = h.i, -1 // a row other than the one a popout hangs off shuts it
        menu_enter(a, b)
    case .Kid:
        if !up {
            return
        }
        a.menu_nav.kid = h.i
        menu_enter(a, b)
    }
}

// Pressing a row does what typing it does (§1). A `:` row IS its own line, holes and all, so it
// is staged the way a `stage` bind row is; a bind row goes down the path its chord goes down.
@(private = "file")
menu_run :: proc(a: ^App, row: menu.Row) {
    if row.id == MENU_STAGE {
        cl_show(a, row.name)
        return
    }
    b := a.binds[row.id]
    bind_dispatch(a, b.chord, b, false)
}

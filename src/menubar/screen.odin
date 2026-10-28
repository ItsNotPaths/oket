package menubar

import "../gfx"
import "../input"
import "../menu"

// The menubar on screen, on keys and under the pointer (MENU.md §4-§6): the interaction layer
// over the bar `build` makes. It never walks a table itself — every row it draws, runs or hits
// came out of the model, so where a row came from is not its business. It changes only its own
// Screen and answers with an Act; whether a menu is up, and what a row runs, are the host's.

// `[menu] show`. Hidden costs the panels nothing and draws over the top row of whatever is
// there; constant fits them one row shorter and always paints the bar. One draw path either
// way: the two differ in that reserved row and in nothing else.
Show :: enum u8 {
    Hidden,
    Constant,
}

// `[menu] palette` (§4). The bar reads as a thing sitting ON the screen rather than one more
// panel, so the default takes the theme the OTHER way round from every document. `dark` and
// `light` say which way round instead of asking.
Palette :: enum u8 {
    Invert,
    Dark,
    Light,
}

// Three grids and no more (MENU.md §4): a popout hangs off a dropdown row and never off another
// popout, so there is nothing to draw at a fourth level.
Part :: enum u8 {
    Bar,
    Drop,
    Kid,
}

Layer :: struct {
    grid: gfx.Grid,
    at:   [2]f32, // the ground's PIXELS: a popup hangs where it likes, and only its size is cells
    on:   bool,
}

Screen :: struct {
    // Painted LAST, over everything: `on` and `at` are also what places the boxes under them,
    // so a layer with no room to draw in gets none.
    layers: [Part]Layer,
    // Where the keys are while the menu is up (§5), the state the pointer moves too. Only
    // meaningful while the host says a menu is up; `open` resets it.
    nav:    menu.Nav,
}

// What the host does after a key or a click.
Act :: enum u8 {
    None, // the menu took it, and nothing else happens
    Open, // a menu is up now, under no primer
    Close,
    Run, // close, then run the row handed back
    Fall, // not the menu's: close, and the chord goes on to the host
}

// A value nobody recognises is the one the file did not have to say.
show_named :: proc(s: string) -> Show {
    return s == "constant" ? .Constant : .Hidden
}

palette_named :: proc(s: string) -> Palette {
    switch s {
    case "dark":
        return .Dark
    case "light":
        return .Light
    }
    return .Invert
}

// The two mid tones were both picked to read on the DARK ground, and neither survives a cream
// one: gruvbox's `Accent` on gruvbox's `Fg` is under 2:1. Darkened until the ladder from the
// ground reads the same way round as it does in the dark — ink, then accent, then dim — so the
// accent still stands out and the dim still recedes.
@(private = "file")
SHADE_ACCENT :: 70
@(private = "file")
SHADE_DIM :: 35

// The theme the three grids are HANDED, which is what keeps `src/menu` from ever learning which
// way round it is drawn. A theme already the way round asked for passes through; the other way
// round swaps the ground and the ink, and a swap ONTO the light ground darkens the two mid tones
// with it.
theme :: proc(ui: gfx.Theme, pal: Palette) -> gfx.Theme {
    dark := gfx.theme_dark(ui)
    light := pal == .Light || (pal == .Invert && dark)
    if light != dark {
        return ui
    }
    th := ui
    th[.Fg], th[.Bg] = ui[.Bg], ui[.Fg]
    if light {
        th[.Accent] = gfx.shade(ui[.Accent], SHADE_ACCENT)
        th[.Dim] = gfx.shade(ui[.Dim], SHADE_DIM)
    }
    return th
}

// --- on screen (§4) ---

// The three grids for `b`: the bar always, the dropdown and its popout while `up`. Every layer
// gets a frame box under it at the rect set here, so no grid paints a ground of its own.
draw :: proc(s: ^Screen, b: menu.Bar, th: gfx.Theme, up: bool) {
    hide(s)
    nav: ^menu.Nav = up ? &s.nav : nil
    layer(s, .Bar, {{0, f32(b.y) * b.cell.y}, b.cols, 1})
    menu.draw_bar(b, &s.layers[.Bar].grid, th, nav)
    if !up {
        return
    }
    if box := menu.drop_box(b, s.nav); menu.has_room(box) {
        layer(s, .Drop, box)
        menu.draw_drop(b, s.nav, &s.layers[.Drop].grid, th)
    }
    if box := menu.kid_box(b, s.nav); menu.has_room(box) {
        layer(s, .Kid, box)
        menu.draw_kids(b, s.nav, &s.layers[.Kid].grid, th)
    }
}

hide :: proc(s: ^Screen) {
    for &l in s.layers {
        l.on = false
    }
}

@(private = "file")
layer :: proc(s: ^Screen, part: Part, box: menu.Box) {
    l := &s.layers[part]
    gfx.grid_resize(&l.grid, box.w, box.h)
    l.at, l.on = box.at, true
}

// The layers sit at the window's own pixels; nothing here slides, so there is no camera in it.
paint :: proc(s: ^Screen, p: ^gfx.Painter, win_w, win_h: i32) {
    cw, ch := gfx.painter_cell(p)
    for &l in s.layers {
        if !l.on {
            continue
        }
        gfx.painter_draw(p, &l.grid, win_w, win_h, l.at,
                         {l.at.x, l.at.y, f32(l.grid.cols * cw), f32(l.grid.rows * ch)})
    }
}

destroy :: proc(s: ^Screen) {
    for &l in s.layers {
        gfx.grid_destroy(&l.grid)
    }
}

// --- on keys (§5) ---

// The nav for a fresh open: the first menu, or the popout of the primer spelled `primer` in the
// `chords` menu. Matched on the SPELLING, because that is all a row carries (§7). A primer with
// no row any more still opens the bar, because the keystroke asked for a menu.
open :: proc(s: ^Screen, b: menu.Bar, primer: string) {
    s.nav = menu.nav(0)
    if primer == "" {
        return
    }
    for m, i in b.menus {
        if m.name != CHORDS {
            continue
        }
        for r, j in m.rows {
            if r.chord != primer {
                continue
            }
            s.nav = menu.nav(i)
            // Walked rather than set, so the scroll follows the row the way it does for a key.
            for _ in 0 ..< j {
                menu.down(b, &s.nav)
            }
            menu.right(b, &s.nav) // the popout, which is what the chord was asking for
            return
        }
    }
}

// The six keys, and nothing else. Anything the menu does not claim falls THROUGH and closes in
// the one keystroke, which is the whole difference between this and a mode: a chord that does
// something keeps doing it.
take :: proc(s: ^Screen, b: menu.Bar, chord: input.Chord) -> (Act, menu.Row) {
    switch {
    case is_key(chord, "LEFT"):
        menu.left(b, &s.nav)
    case is_key(chord, "RGHT"):
        menu.right(b, &s.nav)
    case is_key(chord, "UP"):
        menu.up(b, &s.nav)
    case is_key(chord, "DOWN"):
        menu.down(b, &s.nav)
    case is_key(chord, "RTRN"):
        return enter(s, b)
    case is_key(chord, "ESC"):
        if menu.esc(&s.nav) {
            return .Close, {}
        }
    case:
        return .Fall, {}
    }
    return .None, {}
}

// What `enter` does, whether a key or a click asked for it: a primer's row pops its children out
// and runs nothing, and every other row runs and closes. The row is read BEFORE the nav moves,
// because that is the row being run.
@(private = "file")
enter :: proc(s: ^Screen, b: menu.Bar) -> (Act, menu.Row) {
    row, _ := menu.selected(b, s.nav)
    if _, run := menu.enter(b, &s.nav); !run {
        return .None, {} // a primer, and its children are out now
    }
    return .Run, row
}

// A claimed key is the bare key: `alt+left` is not the menu's left, and `tab+enter` is the
// picker's chord and is not the menu's enter.
@(private = "file")
is_key :: proc(chord: input.Chord, name: string) -> bool {
    code, _ := input.key_code(name)
    return chord == input.Chord{code, {}}
}

// --- on the mouse (§6) ---

// The pointer moves the SAME nav the keys move, so the arrows carry on from the row it left. It
// opens nothing and pops nothing out: passing over a name or a primer must not arm what a press
// is for.
hover :: proc(s: ^Screen, h: menu.Hit) {
    n := &s.nav
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
click :: proc(s: ^Screen, b: menu.Bar, h: menu.Hit, up: bool) -> (Act, menu.Row) {
    switch h.part {
    case .None, .Frame:
    case .Name:
        if up && s.nav.menu == h.i && !menu.popped(s.nav) {
            return .Close, {} // the name that opened it closes it
        }
        s.nav = menu.nav(h.i)
        return .Open, {}
    case .Row:
        if up {
            s.nav.row, s.nav.kid = h.i, -1 // a row other than the one a popout hangs off shuts it
            return enter(s, b)
        }
    case .Kid:
        if up {
            s.nav.kid = h.i
            return enter(s, b)
        }
    }
    return .None, {}
}

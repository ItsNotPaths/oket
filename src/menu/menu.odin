package menu

import "core:unicode/utf8"
import "../gfx"

// The menubar's shape, its keys and its cells, and nothing else (MENU.md §7). Names, rows and a
// nav state go in; boxes, a selection and glyphs come out. A row is four strings and an opaque
// `int` the kernel maps back to a bind or a builtin, so nothing here knows what a bind, a
// builtin, a plugin or a panel is — and `menu_test.odin` builds a bar with a struct literal and
// never reaches for an App, which is the check that it stayed a piece (PANELS.md §9).
//
// Three grids and no more (§4): the bar, one dropdown, one popout. Each is its own grid at its
// own origin, so everything here DRAWS at 0,0 and the box says where the kernel paints it.

// Where the ownership changes, which is the only thing the separators are read off (§1): the
// kernel's own namespaces, then the shared sequence space, then a menu per live plugin.
Region :: enum u8 {
    Kernel,
    Chords,
    Plugin,
}

// One line of a dropdown or a popout (§2). Four columns, any of them empty, and a column no row
// fills costs nothing: a list of bare chords is a narrow box. `tag` is the only one that is
// right-aligned, because it is a mark and not prose — the owner of a row, or a `>` where a
// popout hangs off it.
Row :: struct {
    chord: string,
    name:  string,
    doc:   string,
    tag:   string,
    id:    int, // the kernel's; this package only hands it back
    kids:  []Row, // a primer's children. One level: a kid has none, so there is no fourth grid
}

Menu :: struct {
    name:   string,
    region: Region,
    rows:   []Row,
}

Bar :: struct {
    menus:      []Menu,
    y:          int, // the row the names sit on
    cols, rows: int, // the window, in cells: what is left under the bar is what a list may fill
}

// Where the keys are while a menu is up. The kernel holds one of these in `Pending_Menu`, so
// there is no shut state here: no pending, no menu (§5).
Nav :: struct {
    menu, row, top: int,
    kid, ktop:      int, // `kid` is -1 when no popout is out
}

// A menu opening, through here and not through a literal: a zero `kid` is row 0 of a popout and
// not the absence of one.
nav :: proc(menu: int) -> Nav {
    return {menu = menu, kid = -1}
}

popped :: proc(n: Nav) -> bool {
    return n.kid >= 0
}

rows_of :: proc(b: Bar, n: Nav) -> []Row {
    if n.menu < 0 || n.menu >= len(b.menus) {
        return nil
    }
    return b.menus[n.menu].rows
}

kids_of :: proc(b: Bar, n: Nav) -> []Row {
    rows := rows_of(b, n)
    if n.row < 0 || n.row >= len(rows) {
        return nil
    }
    return rows[n.row].kids
}

// The row the keys are on: the child while a popout is out, the dropdown's row otherwise.
selected :: proc(b: Bar, n: Nav) -> (Row, bool) {
    if popped(n) {
        kids := kids_of(b, n)
        if n.kid < len(kids) {
            return kids[n.kid], true
        }
        return {}, false
    }
    rows := rows_of(b, n)
    if n.row >= 0 && n.row < len(rows) {
        return rows[n.row], true
    }
    return {}, false
}

// --- the keys (§5) ---

// A bar is a ring and so is a list: both ends wrap, so the last menu is one key from the first
// and a short list is walked either way.
left :: proc(b: Bar, n: ^Nav) {
    if popped(n^) {
        n.kid = -1 // the popout first; the menu is still the one you were in
        return
    }
    step(b, n, -1)
}

right :: proc(b: Bar, n: ^Nav) {
    if popped(n^) {
        return // already out, and a popout hangs off nothing
    }
    if it, on := selected(b, n^); on && len(it.kids) > 0 {
        n.kid, n.ktop = 0, 0
        return
    }
    step(b, n, 1)
}

up :: proc(b: Bar, n: ^Nav) {
    walk(b, n, -1)
}

down :: proc(b: Bar, n: ^Nav) {
    walk(b, n, 1)
}

// A primer row pops its children out and runs nothing. Anywhere else the row's id comes back and
// the kernel runs it or stages it, which is the whole of what this package decides.
enter :: proc(b: Bar, n: ^Nav) -> (id: int, run: bool) {
    it, on := selected(b, n^)
    if !on {
        return 0, false
    }
    if len(it.kids) > 0 && !popped(n^) {
        n.kid, n.ktop = 0, 0
        return 0, false
    }
    return it.id, true
}

// The popout, then the menu itself — and the menu is the kernel's pending state, so that half is
// its answer to make.
esc :: proc(n: ^Nav) -> (shut: bool) {
    if popped(n^) {
        n.kid = -1
        return false
    }
    return true
}

@(private)
step :: proc(b: Bar, n: ^Nav, by: int) {
    n^ = nav(wrap(n.menu, len(b.menus), by))
}

@(private)
walk :: proc(b: Bar, n: ^Nav, by: int) {
    if popped(n^) {
        kids := kids_of(b, n^)
        n.kid = wrap(n.kid, len(kids), by)
        follow(&n.ktop, n.kid, len(kids), kid_box(b, n^).h - 2)
        return
    }
    rows := rows_of(b, n^)
    n.row = wrap(n.row, len(rows), by)
    follow(&n.top, n.row, len(rows), drop_box(b, n^).h - 2)
}

@(private)
wrap :: proc(i, count, by: int) -> int {
    if count <= 0 {
        return 0
    }
    return (i + by) %% count
}

// Keep the selection on screen and move by the least it can, the way a view does (§4).
@(private)
follow :: proc(top: ^int, sel, count, h: int) {
    if h <= 0 {
        top^ = 0
        return
    }
    at := clamp(top^, max(sel - h + 1, 0), max(sel, 0))
    top^ = clamp(at, 0, max(count - h, 0))
}

// --- the boxes (§4) ---

// Cells, borders included. The origin is the WINDOW's, for the kernel to paint at; the drawing
// below works at 0,0 in a grid of this size.
Box :: struct {
    x, y, w, h: int,
}

// Two borders and one row is the least a box can hold; under that it is nothing to draw or hit.
// Public because the kernel paints these boxes and a grid it draws nothing into is one it must
// not paint either (MENU.md §4).
has_room :: proc(box: Box) -> bool {
    return box.w >= 3 && box.h >= 3
}

// A name on the bar. Two spaces between names, and ` │ ` where the ownership changes: the
// separator is read off the regions and is written down nowhere (§1).
name_span :: proc(b: Bar, i: int) -> (x, w: int) {
    x = 1
    for m, j in b.menus {
        if j > 0 {
            x += parted(b, j) ? 3 : 2
        }
        if j == i {
            return x, cells(m.name)
        }
        x += cells(m.name)
    }
    return 0, 0
}

// A separator sits left of menu `i` when the region changes there.
@(private)
parted :: proc(b: Bar, i: int) -> bool {
    return i > 0 && b.menus[i - 1].region != b.menus[i].region
}

// The dropdown: left edge under the first letter of its menu's name, as wide as its longest row
// and as tall as the window leaves. A longer list scrolls.
drop_box :: proc(b: Bar, n: Nav) -> Box {
    rows := rows_of(b, n)
    if len(rows) == 0 {
        return {}
    }
    x, _ := name_span(b, n.menu)
    w := min(box_w(rows), b.cols)
    y := b.y + 1
    return {clamp(x, 0, max(b.cols - w, 0)), y, w, min(len(rows) + 2, max(b.rows - y, 0))}
}

// The popout, hard against the dropdown's right edge and level with the row that opened it. It
// slides up and left to fit rather than growing off the window.
kid_box :: proc(b: Bar, n: Nav) -> Box {
    kids := kids_of(b, n)
    if !popped(n) || len(kids) == 0 {
        return {}
    }
    drop := drop_box(b, n)
    w := min(box_w(kids), b.cols)
    h := min(len(kids) + 2, max(b.rows - drop.y, 0))
    x := clamp(drop.x + drop.w, 0, max(b.cols - w, 0))
    return {x, clamp(drop.y + 1 + (n.row - n.top), 0, max(b.rows - h, 0)), w, h}
}

// A pad each side, and two spaces between columns that hold something.
@(private)
box_w :: proc(rows: []Row) -> int {
    w, seen := 4, 0
    for c in widths(rows) {
        if c == 0 {
            continue
        }
        w += seen > 0 ? c + 2 : c
        seen += 1
    }
    return w
}

@(private)
widths :: proc(rows: []Row) -> (w: [4]int) {
    for it in rows {
        w[0] = max(w[0], cells(it.chord))
        w[1] = max(w[1], cells(it.name))
        w[2] = max(w[2], cells(it.doc))
        w[3] = max(w[3], cells(it.tag))
    }
    return
}

// Where a column starts: past the border, the pad and every column before it that holds
// something.
@(private)
col_x :: proc(w: [4]int, i: int) -> int {
    x := 2
    for j in 0 ..< i {
        if w[j] > 0 {
            x += w[j] + 2
        }
    }
    return x
}

// One cell a rune, which is what `grid_write` advances by: the two have to agree or a column
// lands one place from where it was measured.
@(private)
cells :: proc(s: string) -> int {
    return utf8.rune_count_in_string(s)
}

// --- the mouse (§6) ---

Part :: enum u8 {
    None, // not the menu's: the click carries on to the strip
    Frame, // the menu's, and nothing in it
    Name,
    Row,
    Kid,
}

Hit :: struct {
    part: Part,
    i:    int,
}

// Which cell of the window is which row. `n` is nil when no menu is up, and then only the bar's
// own row answers — everything else falls through to the panel under it.
hit :: proc(b: Bar, n: ^Nav, x, y: int) -> Hit {
    if n != nil {
        if h, on := box_hit(kid_box(b, n^), n.ktop, len(kids_of(b, n^)), x, y, .Kid); on {
            return h
        }
        if h, on := box_hit(drop_box(b, n^), n.top, len(rows_of(b, n^)), x, y, .Row); on {
            return h
        }
    }
    if y == b.y {
        for _, i in b.menus {
            nx, nw := name_span(b, i)
            if x >= nx && x < nx + nw {
                return {.Name, i}
            }
        }
        return {.Frame, -1}
    }
    return {.None, -1}
}

@(private)
box_hit :: proc(box: Box, top, count, x, y: int, part: Part) -> (Hit, bool) {
    if !has_room(box) {
        return {}, false
    }
    if x < box.x || x >= box.x + box.w || y < box.y || y >= box.y + box.h {
        return {}, false
    }
    // A row owns its whole line, the border columns at its ends included: an edge that is a row
    // in one column and not in the next is a pixel of nothing to land on.
    if i := top + y - box.y - 1; y > box.y && y < box.y + box.h - 1 && i < count {
        return {part, i}, true
    }
    return {.Frame, -1}, true // a top or bottom border, or past the last row: not a row
}

// --- the cells ---

// The bar's own grid, one row. `n` is nil while no menu is up, the same as it is for `hit`.
draw_bar :: proc(b: Bar, g: ^gfx.Grid, th: gfx.Theme, n: ^Nav = nil) {
    gfx.grid_clear(g, th[.Fg], th[.Bg])
    for m, i in b.menus {
        x, _ := name_span(b, i)
        if parted(b, i) {
            gfx.grid_write(g, x - 2, 0, "│", th[.Dim], th[.Bg])
        }
        if n != nil && n.menu == i {
            gfx.grid_write(g, x, 0, m.name, th[.Bg], th[.Accent])
        } else {
            gfx.grid_write(g, x, 0, m.name, th[.Fg], th[.Bg])
        }
    }
}

// The dropdown's grid. The row a popout hangs off stays lit while it is out, so the popout says
// which row it belongs to.
draw_drop :: proc(b: Bar, n: Nav, g: ^gfx.Grid, th: gfx.Theme) {
    draw_list(g, th, drop_box(b, n), rows_of(b, n), n.top, n.row)
}

draw_kids :: proc(b: Bar, n: Nav, g: ^gfx.Grid, th: gfx.Theme) {
    draw_list(g, th, kid_box(b, n), kids_of(b, n), n.ktop, n.kid)
}

@(private)
draw_list :: proc(g: ^gfx.Grid, th: gfx.Theme, box: Box, rows: []Row, top, sel: int) {
    if !has_room(box) {
        return
    }
    gfx.grid_clear(g, th[.Fg], th[.Bg])
    gfx.grid_box(g, 0, 0, box.w, box.h, th[.Dim], th[.Bg])
    cols := widths(rows)
    for i in 0 ..< box.h - 2 {
        at := top + i
        if at >= len(rows) {
            break
        }
        draw_row(g, 1 + i, box.w, rows[at], cols, th, at == sel)
    }
}

@(private)
draw_row :: proc(g: ^gfx.Grid, y, w: int, it: Row, cols: [4]int, th: gfx.Theme, on: bool) {
    fg, bg := th[.Fg], th[.Bg]
    if on {
        fg, bg = th[.Bg], th[.Accent] // the row the keys are on, and the row a popout hangs off
    }
    for x in 1 ..< w - 1 {
        gfx.grid_put(g, x, y, {' ', fg, bg, {}, 0})
    }
    gfx.grid_write(g, col_x(cols, 0), y, it.chord, on ? fg : th[.Accent], bg)
    gfx.grid_write(g, col_x(cols, 1), y, it.name, fg, bg)
    gfx.grid_write(g, col_x(cols, 2), y, it.doc, on ? fg : th[.Dim], bg)
    gfx.grid_write(g, w - 2 - cells(it.tag), y, it.tag, on ? fg : th[.Dim], bg)
}

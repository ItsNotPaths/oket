package menu

import "core:math"
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
    // What one cell measures. A POPUP IS PLACED IN PIXELS (CHROME.md §11) and only the grid
    // inside it is cells, so this is the one number that crosses between the two here. A zero
    // cell answers in columns, which is what a test with no painter reads in.
    cell:       [2]f32,
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
        follow(&n.ktop, n.kid, len(kids), kid_box(b, n^).h)
        return
    }
    rows := rows_of(b, n^)
    n.row = wrap(n.row, len(rows), by)
    follow(&n.top, n.row, len(rows), drop_box(b, n^).h)
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

// A popup has a pixel origin and a cell-sized grid.
Box :: struct {
    at:   [2]f32,
    w, h: int,
}

// Pixel padding around popup grids. The top edge stays flush with the menu row.
POPUP_PAD :: f32(3)

// The pixels a box covers, which is its cells at this bar's cell size.
@(private)
box_px :: proc(b: Bar, box: Box) -> (w, h: f32) {
    return f32(box.w) * b.cell.x, f32(box.h) * b.cell.y
}

// The visible popup frame around a grid.
popup_rect :: proc(box: Box, cell: [2]f32) -> gfx.Rect {
    w, h := f32(box.w) * cell.x, f32(box.h) * cell.y
    return {box.at.x - POPUP_PAD, box.at.y, w + 2 * POPUP_PAD, h + POPUP_PAD}
}

@(private)
point_in :: proc(r: gfx.Rect, x, y: f32) -> bool {
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

// Floor pixel positions so coordinates left of the grid stay negative.
@(private)
cell_of :: proc(px, cell: f32) -> int {
    return cell > 0 ? int(math.floor(px / cell)) : 0
}

// A drawable popup needs at least one row and the list's minimum width.
has_room :: proc(box: Box) -> bool {
    return box.w >= 3 && box.h >= 1
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

// The dropdown starts under its menu name and scrolls when the window is shorter.
drop_box :: proc(b: Bar, n: Nav) -> Box {
    rows := rows_of(b, n)
    if len(rows) == 0 {
        return {}
    }
    x, _ := name_span(b, n.menu)
    w := min(box_w(rows), b.cols)
    y := b.y + 1
    // Clamp the pixel anchor to the window.
    return {
        {clamp(f32(x) * b.cell.x, 0, max(f32(b.cols - w) * b.cell.x, 0)), f32(y) * b.cell.y},
        w,
        min(len(rows), max(b.rows - y, 0)),
    }
}

// The popout, hard against the dropdown's right edge and level with the row that opened it. It
// slides up and left to fit rather than growing off the window.
kid_box :: proc(b: Bar, n: Nav) -> Box {
    kids := kids_of(b, n)
    if !popped(n) || len(kids) == 0 {
        return {}
    }
    drop := drop_box(b, n)
    dw, _ := box_px(b, drop)
    top := b.y + 1 // the dropdown's own row, which is this popout's ceiling
    w := min(box_w(kids), b.cols)
    h := min(len(kids), max(b.rows - top, 0))
    x := clamp(drop.at.x + dw, 0, max(f32(b.cols - w) * b.cell.x, 0))
    y := clamp(drop.at.y + f32(n.row - n.top) * b.cell.y, 0, max(f32(b.rows - h) * b.cell.y, 0))
    return {{x, y}, w, h}
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

// Hit popups in pixels, then the bar on the ground's cell lattice.
hit :: proc(b: Bar, n: ^Nav, px, py: f32) -> Hit {
    if n != nil {
        if h, on := box_hit(b, kid_box(b, n^), n.ktop, len(kids_of(b, n^)), px, py, .Kid); on {
            return h
        }
        if h, on := box_hit(b, drop_box(b, n^), n.top, len(rows_of(b, n^)), px, py, .Row); on {
            return h
        }
    }
    x, y := cell_of(px, b.cell.x), cell_of(py, b.cell.y)
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
box_hit :: proc(b: Bar, box: Box, top, count: int, px, py: f32, part: Part) -> (Hit, bool) {
    if !has_room(box) || !point_in(popup_rect(box, b.cell), px, py) {
        return {}, false
    }
    w, h := box_px(b, box)
    if !point_in({box.at.x, box.at.y, w, h}, px, py) {
        return {.Frame, -1}, true
    }
    if i := top + cell_of(py - box.at.y, b.cell.y); i < count {
        return {part, i}, true
    }
    return {.Frame, -1}, true
}

// --- the cells ---

// The bar's own grid, one row. `n` is nil while no menu is up, the same as it is for `hit`.
//
// AN UNLIT CELL PAINTS NOTHING. Every grid this package fills has a frame box drawn under it
// (CHROME.md §15 stage 6), so what a menubar puts down is ink and a lit row, never a ground —
// and `src/menu` still never learns where its grids are.
draw_bar :: proc(b: Bar, g: ^gfx.Grid, th: gfx.Theme, n: ^Nav = nil) {
    gfx.grid_clear(g, th[.Fg], gfx.NOTHING)
    for m, i in b.menus {
        x, _ := name_span(b, i)
        if parted(b, i) {
            gfx.grid_write(g, x - 2, 0, "│", th[.Dim], gfx.NOTHING)
        }
        if n != nil && n.menu == i {
            gfx.grid_write(g, x, 0, m.name, th[.Bg], gfx.opaque(th[.Accent]))
        } else {
            gfx.grid_write(g, x, 0, m.name, th[.Fg], gfx.NOTHING)
        }
    }
}

// The dropdown's grid, and WHICH OF ITS ROWS IS LIT — the caller draws that row's ground as a
// box, so the one row with a colour behind it is the one shape here that is not a glyph
// (CHROME.md §6.1). -1 when the selection is scrolled out of the box or there is none. The row
// a popout hangs off stays lit while it is out, so the popout says which row it belongs to.
draw_drop :: proc(b: Bar, n: Nav, g: ^gfx.Grid, th: gfx.Theme) -> int {
    return draw_list(g, th, drop_box(b, n), rows_of(b, n), n.top, n.row)
}

draw_kids :: proc(b: Bar, n: Nav, g: ^gfx.Grid, th: gfx.Theme) -> int {
    return draw_list(g, th, kid_box(b, n), kids_of(b, n), n.ktop, n.kid)
}

@(private)
draw_list :: proc(g: ^gfx.Grid, th: gfx.Theme, box: Box, rows: []Row, top, sel: int) -> int {
    if !has_room(box) {
        return -1
    }
    gfx.grid_clear(g, th[.Fg], gfx.NOTHING)
    cols := widths(rows)
    lit := -1
    for i in 0 ..< box.h {
        at := top + i
        if at >= len(rows) {
            break
        }
        on := at == sel
        if on {
            lit = i
        }
        draw_row(g, i, box.w, rows[at], cols, th, on)
    }
    return lit
}

@(private)
draw_row :: proc(g: ^gfx.Grid, y, w: int, it: Row, cols: [4]int, th: gfx.Theme, on: bool) {
    fg := th[.Fg]
    if on {
        // The row the keys are on, and the row a popout hangs off. Its ink flips because the
        // caller draws its ground as an ACCENT BOX; no row of a list paints a ground of its own.
        fg = th[.Bg]
    }
    gfx.grid_write(g, col_x(cols, 0), y, it.chord, on ? fg : th[.Accent], gfx.NOTHING)
    gfx.grid_write(g, col_x(cols, 1), y, it.name, fg, gfx.NOTHING)
    gfx.grid_write(g, col_x(cols, 2), y, it.doc, on ? fg : th[.Dim], gfx.NOTHING)
    gfx.grid_write(g, w - 2 - cells(it.tag), y, it.tag, on ? fg : th[.Dim], gfx.NOTHING)
}

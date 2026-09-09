package gfx

import "core:strings"

// The screen is one 2D array of cells. Column N sits at N * advance, so hit testing and
// selection are arithmetic, not measurement. A snapshot is text, so screens diff in CI.

Attr :: enum u8 {
    Bold,
    Italic,
    Underline,
    Reverse,
}

Attrs :: bit_set[Attr;u8]

Cell :: struct {
    r:     rune,
    fg:    [3]f32,
    bg:    [3]f32,
    attrs: Attrs,
    // The atlas slot to draw, 0 meaning "resolve `r` yourself". A shaped run fills it, because
    // a ligature or a conjunct is a glyph no codepoint names; chrome leaves it alone and the
    // painter looks the rune up as it always did (IME.md §6).
    slot:  u16,
}

// A glyph drawn OVER a cell rather than in it: a combining mark, whose own width is zero.
// The painter draws these after every cell, blended, so the base glyph stays underneath
// (IME.md §6). Rare, so the list is short and empty on almost every grid.
Mark :: struct {
    cell: i32, // index into `cells`
    r:    rune,
    slot: u16, // as Cell.slot: 0 asks the painter to resolve `r`
}

Grid :: struct {
    cols, rows: int,
    cells:      []Cell,
    marks:      [dynamic]Mark,
}

grid_init :: proc(g: ^Grid, cols, rows: int) -> bool {
    if cols <= 0 || rows <= 0 {
        return false
    }
    g.cols, g.rows = cols, rows
    g.cells = make([]Cell, cols * rows)
    grid_clear(g, {}, {})
    return true
}

grid_destroy :: proc(g: ^Grid) {
    delete(g.cells)
    delete(g.marks)
    g^ = {}
}

grid_resize :: proc(g: ^Grid, cols, rows: int) -> bool {
    if cols == g.cols && rows == g.rows {
        return true
    }
    grid_destroy(g)
    return grid_init(g, cols, rows)
}

grid_clear :: proc(g: ^Grid, fg, bg: [3]f32) {
    for &c in g.cells {
        c = Cell{' ', fg, bg, {}, 0}
    }
    clear(&g.marks)
}

grid_in :: proc(g: ^Grid, x, y: int) -> bool {
    return x >= 0 && y >= 0 && x < g.cols && y < g.rows
}

grid_at :: proc(g: ^Grid, x, y: int) -> ^Cell {
    if !grid_in(g, x, y) {
        return nil
    }
    return &g.cells[y * g.cols + x]
}

// A mark over the cell at x,y. It draws in that cell's colours, but not its attributes: the
// underline belongs to the base and is already drawn under both.
grid_mark :: proc(g: ^Grid, x, y: int, r: rune, slot: u16 = 0) {
    if !grid_in(g, x, y) {
        return
    }
    append(&g.marks, Mark{i32(y * g.cols + x), r, slot})
}

grid_put :: proc(g: ^Grid, x, y: int, c: Cell) {
    if cell := grid_at(g, x, y); cell != nil {
        cell^ = c
    }
}

// Writes left to right from x, stopping at the row's end. Returns the column after the last
// cell written, so callers chain runs without re-measuring.
grid_write :: proc(g: ^Grid, x, y: int, text: string, fg, bg: [3]f32, attrs: Attrs = {}) -> int {
    col := x
    for r in text {
        if col >= g.cols {
            break
        }
        grid_put(g, col, y, Cell{r, fg, bg, attrs, 0})
        col += 1
    }
    return col
}

// A single-line box, from the box-drawing block the fallback atlas carries in full.
grid_box :: proc(g: ^Grid, x, y, w, h: int, fg, bg: [3]f32) {
    if w < 2 || h < 2 {
        return
    }
    for i in 1 ..< w - 1 {
        grid_put(g, x + i, y, Cell{'\u2500', fg, bg, {}, 0})
        grid_put(g, x + i, y + h - 1, Cell{'\u2500', fg, bg, {}, 0})
    }
    for j in 1 ..< h - 1 {
        grid_put(g, x, y + j, Cell{'\u2502', fg, bg, {}, 0})
        grid_put(g, x + w - 1, y + j, Cell{'\u2502', fg, bg, {}, 0})
    }
    grid_put(g, x, y, Cell{'\u250C', fg, bg, {}, 0})
    grid_put(g, x + w - 1, y, Cell{'\u2510', fg, bg, {}, 0})
    grid_put(g, x, y + h - 1, Cell{'\u2514', fg, bg, {}, 0})
    grid_put(g, x + w - 1, y + h - 1, Cell{'\u2518', fg, bg, {}, 0})
}

// The glyphs alone, trailing blanks trimmed. Tests assert on this; colours are deliberately
// absent so a theme edit cannot break a layout test.
grid_snapshot :: proc(g: ^Grid, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for y in 0 ..< g.rows {
        if y > 0 {
            strings.write_rune(&b, '\n')
        }
        row := g.cells[y * g.cols:][:g.cols]
        end := g.cols
        for end > 0 && (row[end - 1].r == ' ' || row[end - 1].r == 0) {
            end -= 1
        }
        for c in row[:end] {
            strings.write_rune(&b, c.r == 0 ? ' ' : c.r)
        }
    }
    return strings.to_string(b)
}

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
}

Grid :: struct {
    cols, rows: int,
    cells:      []Cell,
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
        c = Cell{' ', fg, bg, {}}
    }
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
        grid_put(g, col, y, Cell{r, fg, bg, attrs})
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
        grid_put(g, x + i, y, Cell{'\u2500', fg, bg, {}})
        grid_put(g, x + i, y + h - 1, Cell{'\u2500', fg, bg, {}})
    }
    for j in 1 ..< h - 1 {
        grid_put(g, x, y + j, Cell{'\u2502', fg, bg, {}})
        grid_put(g, x + w - 1, y + j, Cell{'\u2502', fg, bg, {}})
    }
    grid_put(g, x, y, Cell{'\u250C', fg, bg, {}})
    grid_put(g, x + w - 1, y, Cell{'\u2510', fg, bg, {}})
    grid_put(g, x, y + h - 1, Cell{'\u2514', fg, bg, {}})
    grid_put(g, x + w - 1, y + h - 1, Cell{'\u2518', fg, bg, {}})
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

// Cells a rune occupies: 0 for combining marks, 2 for East Asian wide, 1 for everything else.
// Tables generated from the Unicode data (width_table.odin). Below U+0300 everything is one
// column, so nearly all editor content skips the binary searches. ~1 ns a call either way.
rune_width :: proc(r: rune) -> int {
    if r < 0x0300 {
        return r == 0 ? 0 : 1
    }
    if in_ranges(WIDTH_ZERO[:], r) {
        return 0
    }
    if in_ranges(WIDTH_WIDE[:], r) {
        return 2
    }
    return 1
}

@(private = "file")
in_ranges :: proc(rs: [][2]rune, r: rune) -> bool {
    lo, hi := 0, len(rs) - 1
    for lo <= hi {
        mid := (lo + hi) / 2
        switch {
        case r < rs[mid][0]:
            hi = mid - 1
        case r > rs[mid][1]:
            lo = mid + 1
        case:
            return true
        }
    }
    return false
}

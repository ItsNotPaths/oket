package view

import "core:fmt"
import "core:slice"
import "core:unicode/utf8"
import "../desc"
import "../gfx"
import "../txt"

// The kernel's one renderer (§5): a snapshot plus a descriptor become cells. Nothing here
// knows what kind of document it is drawing — a file, a listing and a diff all arrive as text
// and a descriptor, and the branch on `render` is the only place kinds differ.

// The part of the viewport stage 3 needs. §11 owns scrolling, margins and follow.
View :: struct {
    top:    int, // first document line drawn
    cursor: int, // the line relative numbers count from
}

// Bytes [lo,hi) of one document line. A line that does not wrap is one row; `first` is what
// carries the line number, so a wrapped continuation has a blank gutter.
Row :: struct {
    line:   int,
    lo, hi: int,
    first:  bool,
}

draw :: proc(
    g: ^gfx.Grid,
    th: gfx.Theme,
    t: ^txt.Text,
    d: ^desc.Descriptor,
    v: View,
    x, y, w, h: int,
) {
    gut := gutter_width(t, d)
    body := w - gut
    if body <= 0 || h <= 0 {
        return
    }
    if len(d.columns) > 0 {
        draw_columns(g, th, t, d, v, x, y, gut, w, h)
        return
    }
    for r, i in rows(t, d, v.top, body, h) {
        src := txt.text_line(t, r.line, context.temp_allocator)
        put_number(g, th, d, v, x, y + i, gut, r)
        run(g, x + gut, y + i, src[r.lo:r.hi], body, d.tab_width, th[.Fg], th[.Bg])
    }
}

// The visual rows a document lays out to, from `from`, at most `limit` of them. `wrap: none`
// is one row per line and the draw clips it.
rows :: proc(
    t: ^txt.Text,
    d: ^desc.Descriptor,
    from, width, limit: int,
    alloc := context.temp_allocator,
) -> []Row {
    out := make([dynamic]Row, 0, limit, alloc)
    for line := max(from, 0); line < txt.text_line_count(t) && len(out) < limit; line += 1 {
        src := txt.text_line(t, line, alloc)
        if d.wrap == .None || width <= 0 || len(src) == 0 {
            append(&out, Row{line, 0, len(src), true})
            continue
        }
        off, first := 0, true
        for off < len(src) && len(out) < limit {
            end := off + run(nil, 0, 0, src[off:], width, d.tab_width, {}, {})
            if end < len(src) && d.wrap == .Word {
                end = word_break(src, off, end)
            }
            end = max(end, off + rune_size(src[off:])) // a cell narrower than one rune must still advance
            append(&out, Row{line, off, min(end, len(src)), first})
            off, first = end, false
        }
    }
    return out[:]
}

// The text `<name>` resolves to on a line (§5). The kernel reads it out of the descriptor's
// span, so a bind that wants "the path of the row under point" needs no callback into whoever
// produced the document.
field_text :: proc(
    t: ^txt.Text,
    d: ^desc.Descriptor,
    line: int,
    name: string,
    alloc := context.temp_allocator,
) -> (string, bool) {
    lo, hi, ok := desc.field_span(d, line, name)
    if !ok {
        return "", false
    }
    src := txt.text_line(t, line, alloc)
    a := clamp(lo, 0, len(src))
    b := clamp(hi, a, len(src))
    return string(src[a:b]), true
}

gutter_width :: proc(t: ^txt.Text, d: ^desc.Descriptor) -> int {
    if d.numbers == .Off {
        return 0
    }
    return digits(txt.text_line_count(t)) + 1 // one column of air between the number and the text
}

// --- internals ---

// One pass over a row's bytes: places cells when `g` is non-nil, and stops at `width` cells
// either way. Returns the byte offset it stopped at, so the measure and the paint can never
// disagree about where a row ends.
@(private)
run :: proc(g: ^gfx.Grid, x, y: int, src: []u8, width, tab: int, fg, bg: [3]f32) -> int {
    cell, i := 0, 0
    for i < len(src) {
        r, sz := utf8.decode_rune(src[i:])
        w := r == '\t' ? tab - cell % tab : gfx.rune_width(r)
        if cell + w > width {
            break
        }
        if g != nil && w > 0 {
            // A tab is its blanks; a wide rune leaves its continuation cell empty.
            gfx.grid_put(g, x + cell, y, gfx.Cell{r == '\t' ? ' ' : r, fg, bg, {}})
            if r == '\t' {
                for k in 1 ..< w {
                    gfx.grid_put(g, x + cell + k, y, gfx.Cell{' ', fg, bg, {}})
                }
            }
        }
        cell += w
        i += max(sz, 1)
    }
    return i
}

// Back up to the break opportunity nearest the edge. No space on the row means the word is
// wider than the viewport, and the character break stands.
@(private)
word_break :: proc(src: []u8, off, end: int) -> int {
    for i := end; i > off; i -= 1 {
        if src[i - 1] == ' ' || src[i - 1] == '\t' {
            return i
        }
    }
    return end
}

// A listing row is one row: the columns pull their named fields out of the line and pad them,
// so wrap never applies and the line's own bytes are never drawn.
@(private)
draw_columns :: proc(
    g: ^gfx.Grid,
    th: gfx.Theme,
    t: ^txt.Text,
    d: ^desc.Descriptor,
    v: View,
    x, y, gut, w, h: int,
) {
    for i in 0 ..< h {
        line := v.top + i
        if line >= txt.text_line_count(t) {
            break
        }
        put_number(g, th, d, v, x, y + i, gut, Row{line, 0, 0, true})
        col := x + gut
        for c in d.columns {
            left := x + w - col
            if left <= 0 {
                break
            }
            s, _ := field_text(t, d, line, c.name)
            run(g, col, y + i, transmute([]u8)pad(s, c.width, c.align), min(c.width, left),
                d.tab_width, th[.Fg], th[.Bg])
            col += c.width + 1 // one column of air between fields
        }
    }
}

@(private)
pad :: proc(s: string, width: int, align: desc.Align) -> string {
    n := width - cells(s)
    if n <= 0 {
        return s
    }
    blanks := make([]u8, n, context.temp_allocator)
    slice.fill(blanks, ' ')
    b := string(blanks)
    return align == .Right ? fmt.tprintf("%s%s", b, s) : fmt.tprintf("%s%s", s, b)
}

@(private)
put_number :: proc(
    g: ^gfx.Grid,
    th: gfx.Theme,
    d: ^desc.Descriptor,
    v: View,
    x, y, gut: int,
    r: Row,
) {
    if gut == 0 || !r.first {
        return
    }
    n := r.line + 1
    if d.numbers == .Relative && r.line != v.cursor {
        n = abs(r.line - v.cursor)
    }
    s := pad(fmt.tprintf("%d", n), gut - 1, .Right)
    gfx.grid_write(g, x, y, s, th[.Dim], th[.Bg])
}

@(private)
cells :: proc(s: string) -> (n: int) {
    for r in s {
        n += gfx.rune_width(r)
    }
    return
}

@(private)
rune_size :: proc(src: []u8) -> int {
    _, sz := utf8.decode_rune(src)
    return max(sz, 1)
}

@(private)
digits :: proc(n: int) -> int {
    d := 1
    for v := n; v >= 10; v /= 10 {
        d += 1
    }
    return d
}

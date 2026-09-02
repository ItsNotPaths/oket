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

// The kernel's viewport (§11), plus a copy of the caret it is drawing. The caret itself lives
// in the document (txt.Cursor), because it is document state and every motion verb is already
// written against it; this is the copy the frame renders from.
View :: struct {
    top:   int, // first document line drawn
    left:  int, // first cell drawn, for a document that does not wrap
    point: txt.Cursor,
}

// A columns document draws fields, not bytes; one branch in draw, locate and underline each.
@(private)
columnar :: proc(d: ^desc.Descriptor) -> bool {
    return len(d.columns) > 0
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
    if columnar(d) {
        draw_columns(g, th, t, d, v, x, y, gut, w, h)
        return
    }
    for r, i in rows(t, d, v.top, body, h) {
        src := txt.text_line(t, r.line, context.temp_allocator)
        clipped := scrolled(r, src, v.left, d.tab_width)
        put_number(g, th, d, v, x, y + i, gut, r)
        run(g, x + gut, y + i, src[clipped.lo:clipped.hi], body, d.tab_width, th[.Fg], th[.Bg])
        mark_point(g, d, v, x + gut, y + i, body, clipped, src)
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

// The row again with `left` cells dropped off its front. Horizontal scroll is the viewport's
// other axis (§11) and only a `wrap: none` document has one, because a wrapped row cannot run
// off the side.
@(private)
scrolled :: proc(r: Row, src: []u8, left, tab: int) -> Row {
    if left <= 0 {
        return r
    }
    out := r
    out.lo = r.lo + byte_of(src[r.lo:r.hi], left, tab)
    return out
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
        w := advance(r, cell, tab)
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

// A tab runs to the next stop, so how wide a rune draws depends on where it starts. Shared, so
// the paint, the wrap measure and the mouse can never disagree about a column.
@(private)
advance :: proc(r: rune, cell, tab: int) -> int {
    return r == '\t' ? tab - cell % tab : gfx.rune_width(r)
}

// The cell a byte offset sits at inside a row.
@(private)
cell_of :: proc(src: []u8, off, tab: int) -> (cell: int) {
    for i := 0; i < len(src) && i < off; {
        r, sz := utf8.decode_rune(src[i:])
        cell += advance(r, cell, tab)
        i += max(sz, 1)
    }
    return
}

// The byte offset the cell holds, the other way round. Past the end answers the end, which is
// what clicking in the blank right of a short line should do.
@(private)
byte_of :: proc(src: []u8, want, tab: int) -> int {
    cell, i := 0, 0
    for i < len(src) {
        r, sz := utf8.decode_rune(src[i:])
        w := advance(r, cell, tab)
        if cell + w > want {
            break
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
        // A columns document draws its fields, not its bytes, so the caret is the ROW it is on.
        if d.selection != .None {
            lo, hi := txt.cursor_range(v.point)
            if line >= lo.line && line <= hi.line {
                mark(g, x + gut, y + i, 0, w - gut)
            }
        }
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
    if d.numbers == .Relative && r.line != v.point.head.line {
        n = abs(r.line - v.point.head.line)
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

// Reverse video is the caret and the selection both: no theme token to define, and it reads on
// any palette a theme author picks.
@(private)
mark :: proc(g: ^gfx.Grid, x, y, from, to: int, attrs := gfx.Attrs{.Reverse}) {
    for c in from ..< to {
        if cell := gfx.grid_at(g, x + c, y); cell != nil {
            cell.attrs += attrs
        }
    }
}

// The caret and its selection over one drawn row. An empty selection is one cell, which is the
// caret; `selection: none` draws neither, which is what a terminal wants.
@(private)
mark_point :: proc(g: ^gfx.Grid, d: ^desc.Descriptor, v: View, x, y, width: int, r: Row, src: []u8) {
    if d.selection == .None {
        return
    }
    lo, hi := txt.cursor_range(v.point)
    if r.line < lo.line || r.line > hi.line {
        return
    }
    row := src[r.lo:r.hi]
    if lo == hi {
        if r.line != lo.line || lo.col < r.lo || lo.col > r.hi {
            return
        }
        at := cell_of(row, lo.col - r.lo, d.tab_width)
        mark(g, x, y, at, min(at + 1, width))
        return
    }
    if d.selection == .Line {
        mark(g, x, y, 0, width)
        return
    }
    a := r.line == lo.line ? clamp(lo.col, r.lo, r.hi) : r.lo
    b := r.line == hi.line ? clamp(hi.col, r.lo, r.hi) : r.hi
    mark(g, x, y, cell_of(row, a - r.lo, d.tab_width), min(cell_of(row, b - r.lo, d.tab_width), width))
}

// --- the mouse (§8) ---

// Where a cell lands: the document position, and the field the descriptor names there. One walk,
// because a click wants both and hover wants the name. Pixel to cell is the window layer's
// division; nothing here knows what a pixel is.
locate :: proc(
    t: ^txt.Text,
    d: ^desc.Descriptor,
    v: View,
    x, y, w, h: int,
    cx, cy: int,
) -> (
    p: txt.Pos,
    field: string,
    ok: bool,
) {
    if cx < x || cy < y || cx >= x + w || cy >= y + h {
        return {}, "", false
    }
    gut := gutter_width(t, d)
    body := w - gut
    if body <= 0 {
        return {}, "", false
    }
    col := max(cx - x - gut, 0) // the gutter reads as column 0, so a click there still picks the line

    if columnar(d) {
        return locate_columns(t, d, v.top + cy - y, col)
    }

    rs := rows(t, d, v.top, body, h)
    if cy - y >= len(rs) {
        return {}, "", false
    }
    src := txt.text_line(t, rs[cy - y].line, context.temp_allocator)
    r := scrolled(rs[cy - y], src, v.left, d.tab_width)
    p = {r.line, r.lo + byte_of(src[r.lo:r.hi], col, d.tab_width)}
    for f in desc.line_fields(d, r.line) {
        if p.col >= f.lo && p.col < f.hi {
            return p, f.name, true
        }
    }
    return p, "", true
}

// The columns arm: the cell names a column, the column names the line's field.
@(private)
locate_columns :: proc(t: ^txt.Text, d: ^desc.Descriptor, line, col: int) -> (txt.Pos, string, bool) {
    if line >= txt.text_line_count(t) {
        return {}, "", false
    }
    name, over := column_at(d, col)
    if !over {
        return {line, 0}, "", true
    }
    lo, _, named := desc.field_span(d, line, name)
    return {line, named ? lo : 0}, named ? name : "", true
}

// Which column the pointer is over. The widths are the descriptor's, so this and draw_columns
// cannot disagree about where a column starts.
@(private)
column_at :: proc(d: ^desc.Descriptor, cell: int) -> (name: string, ok: bool) {
    at := 0
    for c in d.columns {
        if cell >= at && cell < at + c.width {
            return c.name, true
        }
        at += c.width + 1
    }
    return "", false
}

// --- scrolling (§11) ---

// The wheel and the page keys, in whole lines. The last line stays reachable and the view never
// runs off the end; `overscroll` is what would relax that, and it is not built.
scroll :: proc(v: ^View, t: ^txt.Text, by: int) {
    v.top = clamp(v.top + by, 0, max(txt.text_line_count(t) - 1, 0))
}

// Keep point on screen after a motion. The descriptor's `margin` (scrolloff) lands here.
follow :: proc(v: ^View, h: int) {
    if h <= 0 {
        return
    }
    v.top = clamp(v.top, max(v.point.head.line - h + 1, 0), max(v.point.head.line, 0))
}

// The cell point sits at on its own line. Only this package measures cells, so the caller that
// wants to keep point in view asks for the column rather than counting one of its own.
point_col :: proc(t: ^txt.Text, d: ^desc.Descriptor, v: View) -> int {
    src := txt.text_line(t, v.point.head.line, context.temp_allocator)
    return cell_of(src, min(v.point.head.col, len(src)), d.tab_width)
}

// Columns of context kept between point and either edge, so you can see what you are about to
// type over rather than the caret butting against the clip.
HSCROLL_PAD :: 8

// The same, sideways: hold inside the padded window, then move the minimum. The pad halves out
// on a narrow region, or two pads wider than the space between them would each pull the other
// way. `col` is the cell point sits at, which the caller measures.
follow_col :: proc(v: ^View, col, w: int) {
    if w <= 0 {
        return
    }
    pad := min(HSCROLL_PAD, (w - 1) / 2)
    if col - pad < v.left {
        v.left = max(col - pad, 0)
        return
    }
    if col + pad > v.left + w - 1 {
        v.left = col + pad - w + 1
    }
}

// The hover underline (§8): the field a bound click would act on, in the cells it was drawn in.
// The kernel asks the bind table and draws this; no surface is involved.
underline :: proc(
    g: ^gfx.Grid,
    t: ^txt.Text,
    d: ^desc.Descriptor,
    v: View,
    x, y, w, h: int,
    line, lo, hi: int,
) {
    gut := gutter_width(t, d)
    body := w - gut
    if body <= 0 {
        return
    }
    if columnar(d) {
        // A columns document draws the field padded in its column, not where its bytes sit, and
        // one line is one row.
        row := line - v.top
        if row < 0 || row >= h {
            return
        }
        at := 0
        for c in d.columns {
            a, b, named := desc.field_span(d, line, c.name)
            if named && a == lo && b == hi {
                mark(g, x + gut, y + row, at, min(at + c.width, body), {.Underline})
                return
            }
            at += c.width + 1
        }
        return
    }
    // Through the rows the draw laid out, so a wrapped span underlines every row it covers and
    // hover cannot disagree with the paint about which one a field is on.
    for row, i in rows(t, d, v.top, body, h) {
        r := scrolled(row, txt.text_line(t, row.line, context.temp_allocator), v.left, d.tab_width)
        if r.line != line || hi <= r.lo || lo >= r.hi {
            continue
        }
        src := txt.text_line(t, r.line, context.temp_allocator)[r.lo:r.hi]
        a := clamp(lo, r.lo, r.hi) - r.lo
        b := clamp(hi, r.lo, r.hi) - r.lo
        mark(g, x + gut, y + i, cell_of(src, a, d.tab_width),
             min(cell_of(src, b, d.tab_width), body), {.Underline})
    }
}

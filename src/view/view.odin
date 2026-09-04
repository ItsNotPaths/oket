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

// Cells of indent a line draws at (§5). ONE rule for both arms: the whole row moves in, the
// line's own text in one and its columns in the other, so a tree, an outline and a folded
// region are the same number and no column is a special case. The unit is the document's own
// tab width, so a tree says how wide a level is by saying what a tab is worth.
@(private)
indent :: proc(d: ^desc.Descriptor, width, line: int) -> int {
    return min(desc.line_depth(d, line) * d.tab_width, max(width - 1, 0))
}

// A run of cells that draw in colours of their own. Byte offsets from the line's start, like a
// Field, and sorted by line so a lookup is a binary search and a short scan.
//
// This is §5's `spans` at the one place that needs it now. The terminal publishes it —
// libvterm's colours already resolved against the theme — so nothing below here knows what an
// SGR is, and stage 11 moves where the runs are STORED rather than inventing the mechanism.
Style :: struct {
    line:   int,
    lo, hi: int,
    fg, bg: [3]f32,
    attrs:  gfx.Attrs,
}

// Bytes [lo,hi) of one line of the DRAWN document. A line that does not wrap is one row;
// `first` is what carries the line number, so a wrapped continuation has a blank gutter.
//
// `src` is the ORIGINAL line the row shows (§6), and -1 when a stage inserted the whole of it.
// It is what every descriptor lookup is keyed by — the number, the depth, the fields and the
// spans all belong to the document being edited, not to the one on screen. With no pipeline the
// two spaces are one and `src` is `line`.
Row :: struct {
    line:   int,
    lo, hi: int,
    first:  bool,
    src:    int,
}

draw :: proc(
    g: ^gfx.Grid,
    th: gfx.Theme,
    t: ^txt.Text,
    d: ^desc.Descriptor,
    v: View,
    x, y, w, h: int,
    styles: []Style = nil,
    // The caret and its selection, which only the FOCUSED panel draws (PANELS.md §3): reverse
    // video in a panel the keys are not aimed at says the next keystroke lands there.
    point := true,
    // The position map (§6), when a view pipeline built `t` out of something else. nil is a
    // document nobody derived, and every lookup through it is then the identity.
    dv: ^Derived = nil,
    // What a view STAGE published over its own output (§5), in the DRAWN document's own lines.
    // `styles` above is the span store's, measured over original bytes; a fold marker and a
    // popup box have none, so they could not be said that way.
    over: []Style = nil,
) {
    gut := gutter_width(t, d, dv)
    body := w - gut
    if body <= 0 || h <= 0 {
        return
    }
    if columnar(d) {
        draw_columns(g, th, t, d, v, x, y, gut, w, h, point, dv)
        return
    }
    for r, i in rows(t, d, v.top, body, h, dv) {
        src := txt.text_line(t, r.line, context.temp_allocator)
        clipped := scrolled(r, src, v.left, d.tab_width)
        ind := indent(d, body, r.src)
        put_number(g, th, d, v, x, y + i, gut, r)
        left := x + gut + ind
        run(g, left, y + i, src[clipped.lo:clipped.hi], body - ind, d.tab_width, th[.Fg], th[.Bg])
        restyle(g, t, d, dv, left, y + i, body - ind, clipped, src, styles)
        overstyle(g, d, left, y + i, body - ind, clipped, src, over)
        if point {
            mark_point(g, t, d, dv, v, left, y + i, body - ind, clipped, src)
        }
    }
}

// The style runs covering one drawn row, painted over what `run` just placed. Before
// mark_point, so the caret and the selection still read on top of a coloured cell.
@(private)
restyle :: proc(
    g: ^gfx.Grid,
    t: ^txt.Text,
    d: ^desc.Descriptor,
    dv: ^Derived,
    x, y, width: int,
    r: Row,
    src: []u8,
    styles: []Style,
) {
    if r.src < 0 {
        return // nothing was measured over a marker, so nothing colours one
    }
    row := src[r.lo:r.hi]
    dls, ols := line_offs(t, dv, r)
    for st in line_styles(styles, r.src) {
        for part in parts(dv, r, dls, ols + st.lo, ols + st.hi) {
            paint(g, d, row, x, y, width, part[0] - r.lo, part[1] - r.lo, st)
        }
    }
}

// The same over a stage's own runs, which need no map: they were measured against the document
// being drawn. Text a stage inserted is the whole reason this exists — `restyle` above declines
// a row with no original line, and a fold marker is exactly that row.
@(private)
overstyle :: proc(
    g: ^gfx.Grid,
    d: ^desc.Descriptor,
    x, y, width: int,
    r: Row,
    src: []u8,
    over: []Style,
) {
    row := src[r.lo:r.hi]
    for st in line_styles(over, r.line) {
        paint(g, d, row, x, y, width, max(st.lo, r.lo) - r.lo, min(st.hi, r.hi) - r.lo, st)
    }
}

// One run of a row's bytes, restyled in place. Cells, not bytes: a tab is one byte and eight of
// these.
@(private = "file")
paint :: proc(g: ^gfx.Grid, d: ^desc.Descriptor, row: []u8, x, y, width, a, b: int, st: Style) {
    if a >= b {
        return
    }
    for cell in cell_of(row, a, d.tab_width) ..< min(cell_of(row, b, d.tab_width), width) {
        if c := gfx.grid_at(g, x + cell, y); c != nil {
            c.fg, c.bg, c.attrs = st.fg, st.bg, st.attrs
        }
    }
}

// The row's line as offsets: where it starts in the DRAWN document, and where the line it shows
// starts in the ORIGINAL. One document, and one number, when there is no map.
@(private)
line_offs :: proc(t: ^txt.Text, dv: ^Derived, r: Row) -> (dls, ols: int) {
    return txt.text_line_start(t, r.line), txt.text_line_start(original(dv, t), max(r.src, 0))
}

// Every run on one line, in the order they were published.
@(private)
line_styles :: proc(styles: []Style, line: int) -> []Style {
    lo, hi := 0, len(styles)
    for lo < hi {
        mid := (lo + hi) / 2
        if styles[mid].line < line {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    hi = lo
    for hi < len(styles) && styles[hi].line == line {
        hi += 1
    }
    return styles[lo:hi]
}

// The visual rows a document lays out to, from `from`, at most `limit` of them. `wrap: none`
// is one row per line and the draw clips it.
rows :: proc(
    t: ^txt.Text,
    d: ^desc.Descriptor,
    from, width, limit: int,
    dv: ^Derived = nil,
    alloc := context.temp_allocator,
) -> []Row {
    out := make([dynamic]Row, 0, limit, alloc)
    for line := max(from, 0); line < txt.text_line_count(t) && len(out) < limit; line += 1 {
        src := txt.text_line(t, line, alloc)
        orig := src_line(dv, t, line)
        // An indented line wraps in what is left of the row, and every row it takes is indented
        // — a hanging indent, and the reason the width is per line rather than per document.
        avail := width - indent(d, width, orig)
        if d.wrap == .None || avail <= 0 || len(src) == 0 {
            append(&out, Row{line, 0, len(src), true, orig})
            continue
        }
        off, first := 0, true
        for off < len(src) && len(out) < limit {
            end := off + run(nil, 0, 0, src[off:], avail, d.tab_width, {}, {})
            if end < len(src) && d.wrap == .Word {
                end = word_break(src, off, end)
            }
            end = max(end, off + rune_size(src[off:])) // a cell narrower than one rune must still advance
            append(&out, Row{line, off, min(end, len(src)), first, orig})
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
//
// A field carrying a `value` answers with it instead: the span is where the link was DRAWN and
// the value is what it POINTS AT, and a browser row showing a bare name is the case that needs
// the two to differ (desc.Field).
field_text :: proc(
    t: ^txt.Text,
    d: ^desc.Descriptor,
    line: int,
    name: string,
    dv: ^Derived = nil,
    alloc := context.temp_allocator,
) -> (string, bool) {
    f, ok := desc.field_of(d, line, name)
    if !ok {
        return "", false
    }
    if f.value != "" {
        return f.value, true
    }
    // A field is the ORIGINAL's: its span was measured over bytes no stage had touched yet.
    src := txt.text_line(original(dv, t), line, alloc)
    a := clamp(f.lo, 0, len(src))
    b := clamp(f.hi, a, len(src))
    return string(src[a:b]), true
}

// The widest number the gutter can show is an ORIGINAL line's, so a fold does not narrow it.
gutter_width :: proc(t: ^txt.Text, d: ^desc.Descriptor, dv: ^Derived = nil) -> int {
    if d.numbers == .Off {
        return 0
    }
    n := txt.text_line_count(original(dv, t))
    return digits(n) + 1 // one column of air between the number and the text
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
    point: bool,
    dv: ^Derived,
) {
    for i in 0 ..< h {
        line := v.top + i
        if line >= txt.text_line_count(t) {
            break
        }
        orig := src_line(dv, t, line)
        put_number(g, th, d, v, x, y + i, gut, Row{line, 0, 0, true, orig})
        col := x + gut + indent(d, w - gut, orig)
        for c in d.columns {
            left := x + w - col
            if left <= 0 {
                break
            }
            s, _ := field_text(t, d, orig, c.name, dv)
            run(g, col, y + i, transmute([]u8)pad(s, c.width, c.align), min(c.width, left),
                d.tab_width, th[.Fg], th[.Bg])
            col += c.width + 1 // one column of air between fields
        }
        // AFTER the columns, never before: `run` writes whole cells, attributes included, so a
        // mark laid down first survives only where no column reached — the row lit everywhere
        // except its own text. A columns document draws its fields and not its bytes, so what
        // is marked is the whole ROW rather than a span of it.
        if point && d.selection != .None && orig >= 0 {
            lo, hi := txt.cursor_range(v.point)
            if orig >= lo.line && orig <= hi.line {
                mark(g, x + gut, y + i, 0, w - gut)
            }
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
    if gut == 0 || !r.first || r.src < 0 {
        return // an inserted line stands for none of the original, so it is numbered by none
    }
    n := r.src + 1
    if d.numbers == .Relative && r.src != v.point.head.line {
        n = abs(r.src - v.point.head.line)
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
mark_point :: proc(
    g: ^gfx.Grid,
    t: ^txt.Text,
    d: ^desc.Descriptor,
    dv: ^Derived,
    v: View,
    x, y, width: int,
    r: Row,
    src: []u8,
) {
    if d.selection == .None || r.src < 0 {
        return
    }
    lo, hi := txt.cursor_range(v.point) // ORIGINAL positions: the caret never leaves that space
    if r.src < lo.line || r.src > hi.line {
        return
    }
    row := src[r.lo:r.hi]
    if lo == hi {
        mark_caret(g, t, d, dv, x, y, width, r, row, lo)
        return
    }
    if d.selection == .Line {
        mark(g, x, y, 0, width)
        return
    }
    // The selection as one range of the ORIGINAL, clipped to this row by the map. So a selection
    // over a fold paints the visible pieces of itself and leaves the marker between them dark:
    // what is lit is what the user selected, never what a stage added.
    orig := original(dv, t)
    dls := txt.text_line_start(t, r.line)
    for part in parts(dv, r, dls, txt.text_off(orig, lo), txt.text_off(orig, hi)) {
        mark(g, x, y, cell_of(row, part[0] - r.lo, d.tab_width),
             min(cell_of(row, part[1] - r.lo, d.tab_width), width))
    }
}

// The caret: one cell, on the row the map says the head's byte is drawn in. Off screen when the
// head sits in a hidden run — motion never leaves it there.
@(private)
mark_caret :: proc(
    g: ^gfx.Grid,
    t: ^txt.Text,
    d: ^desc.Descriptor,
    dv: ^Derived,
    x, y, width: int,
    r: Row,
    row: []u8,
    p: txt.Pos,
) {
    at, on := view_pos(dv, t, p)
    if !on || at.line != r.line || at.col < r.lo || at.col > r.hi {
        return
    }
    cell := cell_of(row, at.col - r.lo, d.tab_width)
    mark(g, x, y, cell, min(cell + 1, width))
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
    dv: ^Derived = nil,
) -> (
    p: txt.Pos,
    field: string,
    ok: bool,
) {
    if cx < x || cy < y || cx >= x + w || cy >= y + h {
        return {}, "", false
    }
    gut := gutter_width(t, d, dv)
    body := w - gut
    if body <= 0 {
        return {}, "", false
    }
    col := max(cx - x - gut, 0) // the gutter reads as column 0, so a click there still picks the line

    if columnar(d) {
        line := v.top + cy - y
        orig := src_line(dv, t, line)
        return locate_columns(t, d, line, orig, col - indent(d, body, orig))
    }

    rs := rows(t, d, v.top, body, h, dv)
    if cy - y >= len(rs) {
        return {}, "", false
    }
    src := txt.text_line(t, rs[cy - y].line, context.temp_allocator)
    r := scrolled(rs[cy - y], src, v.left, d.tab_width)
    col = max(col - indent(d, body, r.src), 0)
    p = {r.line, r.lo + byte_of(src[r.lo:r.hi], col, d.tab_width)}
    // The answer is the ORIGINAL's (§6). A cell of text a stage inserted has no byte of its own,
    // so it answers the real one beside it — the same clamp typing at either edge already gets.
    p, _ = src_pos(dv, t, p)
    // The NARROWEST field covering the cell, which is the most specific thing under the
    // pointer. A row that names its whole line as well as the parts of it — a listing whose
    // text is `ls -la` output — has both, and the wider one would answer for every cell of it.
    best, found := desc.Field{}, false
    for f in desc.line_fields(d, p.line) {
        if p.col >= f.lo && p.col < f.hi && (!found || f.hi - f.lo < best.hi - best.lo) {
            best, found = f, true
        }
    }
    return p, found ? best.name : "", true
}

// The columns arm: the cell names a column, the column names the line's field.
@(private)
locate_columns :: proc(
    t: ^txt.Text,
    d: ^desc.Descriptor,
    line, orig, col: int,
) -> (txt.Pos, string, bool) {
    if line >= txt.text_line_count(t) || orig < 0 {
        return {}, "", false
    }
    name, over := column_at(d, col)
    if !over {
        return {orig, 0}, "", true
    }
    lo, _, named := desc.field_span(d, orig, name)
    return {orig, named ? lo : 0}, named ? name : "", true
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

// Keep point on screen after a motion, and `reveal` with it (§6): `top` is a line of the DRAWN
// document and the caret is a position in the original, so the map is what puts them in one
// space. The descriptor's `margin` (scrolloff) lands here.
follow :: proc(v: ^View, h: int, t: ^txt.Text = nil, dv: ^Derived = nil) {
    if h <= 0 {
        return
    }
    at, _ := view_pos(dv, t, v.point.head)
    v.top = clamp(v.top, max(at.line - h + 1, 0), max(at.line, 0))
}

// The cell point sits at on its own line. Only this package measures cells, so the caller that
// wants to keep point in view asks for the column rather than counting one of its own.
point_col :: proc(t: ^txt.Text, d: ^desc.Descriptor, v: View, dv: ^Derived = nil) -> int {
    at, _ := view_pos(dv, t, v.point.head)
    src := txt.text_line(t, at.line, context.temp_allocator)
    return cell_of(src, min(at.col, len(src)), d.tab_width)
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
    line, lo, hi: int, // the field, in the ORIGINAL: a descriptor holds no other coordinates
    dv: ^Derived = nil,
) {
    gut := gutter_width(t, d, dv)
    body := w - gut
    if body <= 0 {
        return
    }
    if columnar(d) {
        // A columns document draws the field padded in its column, not where its bytes sit, and
        // one line is one row.
        vp, on := view_pos(dv, t, {line, 0})
        if !on {
            return
        }
        row := vp.line - v.top
        if row < 0 || row >= h {
            return
        }
        at := indent(d, body, line)
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
    for row, i in rows(t, d, v.top, body, h, dv) {
        r := scrolled(row, txt.text_line(t, row.line, context.temp_allocator), v.left, d.tab_width)
        if r.src != line {
            continue
        }
        src := txt.text_line(t, r.line, context.temp_allocator)[r.lo:r.hi]
        dls, ols := line_offs(t, dv, r)
        ind := indent(d, body, r.src)
        for part in parts(dv, r, dls, ols + lo, ols + hi) {
            mark(g, x + gut + ind, y + i, cell_of(src, part[0] - r.lo, d.tab_width),
                 min(cell_of(src, part[1] - r.lo, d.tab_width), body - ind), {.Underline})
        }
    }
}

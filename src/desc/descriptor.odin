package desc

import "core:slice"
import "core:strings"
import "../input"
import "../rc"

// How the kernel renders and routes a document (§5). Immutable and refcounted: a write
// publishes a new one, so a reader holding the descriptor its generation named keeps reading
// the same bytes however the document moves. Same rule as the text arena.
//
// A field belongs here only if the KERNEL must know it to render or route. Plugin state,
// config and binds each have their own home, and that test is what keeps this from becoming a
// junk drawer.

Render :: enum u8 {
    Text,  // a line is text; wrap, tabs and line numbers apply
    Grid,  // a line is a physical row — the terminal (stage 6)
    Cells, // the plugin paints (stage 7)
}

Wrap :: enum u8 {
    None,
    Word,
    Char,
}

Numbers :: enum u8 {
    Off,
    Absolute,
    Relative,
}

Align :: enum u8 {
    Left,
    Right,
}

// The drag granularity, and what an empty selection looks like (§5, §8): a browser selects
// rows, an editor selects characters. `block` arrives with block editing.
Selection :: enum u8 {
    Char,
    Line,
    None,
}

Column :: struct {
    name:  string,
    width: int,
    align: Align,
}

// A named byte span inside one line, offsets from that line's start. Sorted by line, so a
// lookup is a binary search and a short scan.
Field :: struct {
    line:   int,
    name:   string,
    lo, hi: int,
}

Descriptor :: struct {
    rc:        int, // atomic
    render:    Render,
    wrap:      Wrap,
    numbers:   Numbers,
    // The context a chord lands in while this document has the keys. The kernel must know it to
    // ROUTE, which is the test that puts it here rather than in plugin state (§5, §8).
    ctx:       input.Bind_Ctx,
    selection: Selection,
    tab_width: int,
    columns:   []Column,
    fields:    []Field,
}

DEFAULT :: Descriptor {
    render    = .Text,
    wrap      = .None,
    numbers   = .Off,
    ctx       = .Text,
    selection = .Char,
    tab_width = 4,
}

// Takes a value, answers the owned immutable copy: names and slices are cloned, so the
// caller's builder may die the moment this returns.
new_from :: proc(d: Descriptor) -> ^Descriptor {
    out := new(Descriptor)
    out^ = d
    out.rc = 1
    out.tab_width = max(d.tab_width, 1)
    if out.ctx == .Global { // no document is Global; the zero value means "unset"
        out.ctx = .Text
    }
    out.columns = slice.clone(d.columns)
    for &c in out.columns {
        c.name = strings.clone(c.name)
    }
    out.fields = slice.clone(d.fields)
    for &f in out.fields {
        f.name = strings.clone(f.name)
    }
    slice.stable_sort_by(out.fields, proc(a, b: Field) -> bool {return a.line < b.line})
    return out
}

retain :: proc(d: ^Descriptor) {
    rc.retain(&d.rc)
}

release :: proc(d: ^Descriptor) {
    if d == nil || !rc.release(&d.rc) {
        return
    }
    for c in d.columns {
        delete(c.name)
    }
    for f in d.fields {
        delete(f.name)
    }
    delete(d.columns)
    delete(d.fields)
    free(d)
}

// Every field on one line, in the order they were given.
line_fields :: proc(d: ^Descriptor, line: int) -> []Field {
    lo := lower_bound(d.fields, line)
    hi := lo
    for hi < len(d.fields) && d.fields[hi].line == line {
        hi += 1
    }
    return d.fields[lo:hi]
}

// The span `<name>` names on this line (§5). Byte offsets from the line's start; the caller
// slices the text, because a descriptor holds no text.
field_span :: proc(d: ^Descriptor, line: int, name: string) -> (lo, hi: int, ok: bool) {
    for f in line_fields(d, line) {
        if f.name == name {
            return f.lo, f.hi, true
        }
    }
    return 0, 0, false
}

@(private)
lower_bound :: proc(fields: []Field, line: int) -> int {
    lo, hi := 0, len(fields)
    for lo < hi {
        mid := (lo + hi) / 2
        if fields[mid].line < line {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}

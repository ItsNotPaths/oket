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
    // The escape hatch (§5): a plugin that genuinely paints. RESERVED AND NOT BUILT — a
    // renderer arm for it is a drawing API, the line §12 draws, so the seam refuses it
    // rather than drawing it as text.
    Cells,
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

// Where the viewport sits as the document grows (§5, §11). `tail` is the terminal's live
// bottom; the kernel's viewport is the only scroll code a session has.
Follow :: enum u8 {
    None,
    Tail,
}

// Where a chord the bind table did not claim, and a typed rune, go (§5, §8). `raw` is the
// terminal: the document has a job of its own and the miss falls through to it. Anything else
// reports, because a silent no-op is the thing §8 exists to prevent.
Input :: enum u8 {
    Bound,
    Raw,
}

// Who reads a click (§5, §8). `bound` is the default and needs no code at all: the kernel moves
// point and the bind table answers. `events` is a document that took the mouse over — a TUI
// that enabled tracking — and gets the button, the cell and the wheel raw.
Mouse :: enum u8 {
    Bound,
    Events,
}

// The drag granularity, and what an empty selection looks like (§5, §8): a browser selects
// rows, an editor selects characters. `block` arrives with block editing.
Selection :: enum u8 {
    Char,
    Line,
    None,
}

// Who published a style run (§5's `spans`, §9). Fixed priority, lowest first: a diagnostic
// outranks syntax, a search hit outranks both, and the store merges in this order so nothing
// merges by hand.
//
// Here rather than in the store, which owns the runs, because the SEAM names it too and the
// seam mirrors txt's layouts rather than importing them (`plug_read.odin`'s size asserts).
// Both sides already read their vocabulary out of this package.
//
// Selection is not a layer. The kernel owns the cursors and the renderer reads them straight,
// so a layer for it would be a second copy of the same truth.
Layer :: enum u8 {
    Syntax,
    Semantic,
    Diagnostic,
    Search,
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
    // The ring lane, and the narrow tier of the bind table (§5). 0 is no kind: a document that
    // belongs to no lane and whose keys are only its context's.
    kind:      input.Kind,
    // The file this document is, or "". What makes `:w` mean something, and what the bar and
    // `:ls` name it by.
    file:      string,
    selection: Selection,
    follow:    Follow,
    input:     Input,
    mouse:     Mouse,
    // Does typing reach this document. A listing is not a text field, and at stage 5 only the
    // command line says yes: nothing types into a document until the editor plugin does.
    editable:  bool,
    tab_width: int,
    columns:   []Column,
    fields:    []Field,
    // How deep each line sits, indexed by line (§5). One field carries a file tree, an outline
    // and folding; a line past the end is depth 0, so a flat document publishes none of it.
    depth:     []int,
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
    out.file = strings.clone(d.file)
    out.columns = slice.clone(d.columns)
    for &c in out.columns {
        c.name = strings.clone(c.name)
    }
    out.fields = slice.clone(d.fields)
    for &f in out.fields {
        f.name = strings.clone(f.name)
    }
    out.depth = slice.clone(d.depth)
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
    delete(d.file)
    delete(d.columns)
    delete(d.fields)
    delete(d.depth)
    free(d)
}

// The indent level of a line. Total, because the renderer asks for every line it draws and a
// document that carries no depth at all is the common case.
line_depth :: proc(d: ^Descriptor, line: int) -> int {
    return line >= 0 && line < len(d.depth) ? max(d.depth[line], 0) : 0
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

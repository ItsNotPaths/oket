package desc

import "core:slice"
import "core:strings"
import "../input"
import "../rc"
import "../shape"

// How the kernel renders and routes a document (§5). Immutable and refcounted: a write
// publishes a new one, so a reader holding the descriptor its generation named keeps reading
// the same bytes however the document moves. Same rule as the text arena.
//
// A field belongs here only if the KERNEL must know it to render or route. Plugin state,
// config and binds each have their own home, and that test is what keeps this from becoming a
// junk drawer.

// `shape` owns the vocabulary; `desc` owns the refcounted struct made OF it, and names the
// parts so no call site has to know which package a row's pieces live in. Named and not copied,
// because the seam reads the same declarations and a second copy is a second thing to reorder
// (shape.odin's asserts).
Render :: shape.Render
Wrap :: shape.Wrap
Numbers :: shape.Numbers
Align :: shape.Align
Follow :: shape.Follow
Input :: shape.Input
Mouse :: shape.Mouse
Selection :: shape.Selection
Chan :: shape.Chan
Chans :: shape.Chans

Column :: shape.Column
Field :: shape.Field

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
        f.value = strings.clone(f.value)
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
        delete(f.value)
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
    f := field_of(d, line, name) or_return
    return f.lo, f.hi, true
}

// The whole of it, for the caller that wants what the field IS as well as where it was drawn.
field_of :: proc(d: ^Descriptor, line: int, name: string) -> (Field, bool) {
    for f in line_fields(d, line) {
        if f.name == name {
            return f, true
        }
    }
    return {}, false
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

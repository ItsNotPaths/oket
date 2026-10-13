package plug

import "core:c"
import "lues:abi"
import "../shape"

// oket's half of the plugin seam: what lues's ABI (lues:abi) does not know. `oket.h` beside it
// is the same declarations in C, and every struct asserts its size so the two cannot drift.
//
// A plugin is a lues plugin: it exports `lues_main`, gets a `^abi.Api`, and reads and writes
// documents through lues's calls. oket adds a tail after those calls (Api below) and a side view
// behind every snapshot (`Snapshot.app` points at a Side).
//
// What oket reads off lues's own types:
//   abi.Edit.tag        the caret that asked for the edit (Cursor.id), carried onto its result
//   abi.Span.attrs      shape.Attrs bits
//   .Forget (submit)    REGEN: derived text, so the carets stay on their rows and nothing undoes

API :: 12

// Ids below this are the base vocabulary (shape.Style); the rest were interned.
TOKEN_BASE :: abi.Token(len(shape.Style))

Pos :: struct {
    line: c.ptrdiff_t,
    col:  c.ptrdiff_t, // BYTES into the line
}

Cursor :: struct {
    anchor: Pos,
    head:   Pos,
    goal:   c.ptrdiff_t,
    id:     u32,
    _pad:   [4]u8,
}

// A run no cell on screen stands for (a fold), in the document's own coordinates.
Range :: struct {
    lo: Pos,
    hi: Pos,
}

// Names are pointer plus length and NEVER NUL-terminated.
Column :: struct {
    name:     [^]u8,
    name_len: c.size_t,
    width:    c.int32_t,
    align:    shape.Align,
    _:        [3]u8,
}

// `ctx` is absent on purpose: a kind's context is fixed where the kind is registered.
Descriptor :: struct {
    file:      [^]u8,
    file_len:  c.size_t,
    columns:   [^]Column,
    ncolumns:  c.size_t,
    // One per LINE, dense and in line order. A short array leaves the rest at depth 0.
    depth:     [^]c.int32_t,
    ndepth:    c.size_t,
    kind:      abi.Kind,
    tab_width: c.int32_t,
    render:    shape.Render,
    wrap:      shape.Wrap,
    numbers:   shape.Numbers,
    selection: shape.Selection,
    follow:    shape.Follow,
    input:     shape.Input,
    mouse:     shape.Mouse,
    editable:  b8,
}

// Snapshot.app: the document as oket sees it, at the snapshot's generation.
Side :: struct {
    desc:     ^Descriptor,
    cursors:  [^]Cursor,
    ncursors: c.size_t,
    primary:  c.size_t,
    // Empty inside a view stage: the text handed to one is already derived.
    hidden:   [^]Range,
    nhidden:  c.size_t,
}

// The kernel's motions, in txt.Motion's order (plug.odin asserts it).
Motion :: enum c.int32_t {
    Left,
    Right,
    Word_Left,
    Word_Right,
    Home,
    End,
    Doc_Start,
    Doc_End,
    Up,
    Down,
    Para_Up,
    Para_Down,
}

// Where a revealed span lands in the viewport (§11).
Reveal :: enum c.int32_t {
    Nearest, // scroll as little as it takes
    Center,
    Top,
}

// --- the view pipeline (VIEWS.md §5) ---

// `edits` are against the text the stage was handed, sorted by `lo` and disjoint. `spans` are
// over the stage's OWN OUTPUT. Both strided by `size`, and copied before the call returns.
View_Out :: struct {
    edits:  [^]abi.Edit,
    nedits: c.size_t,
    spans:  [^]abi.Span,
    nspans: c.size_t,
}

// Non-zero is the latch: call again next frame.
View_Fn :: #type proc "c" (api: ^abi.Api, self: abi.Self, at: ^abi.At, out: ^View_Out) -> c.int32_t

// --- the world (§12) ---

Pane :: struct {
    doc:        abi.Doc_Handle,
    // The BODY, in cells: the gutter is outside it, and `y` counts from the top of the surface.
    x, y, w, h: c.int32_t,
    top:        c.int32_t, // the first line drawn, in the DERIVED document
    focused:    b8,
    _:          [3]u8,
}

World :: struct {
    panes:  [^]Pane,
    npanes: c.size_t,
    cols:   c.int32_t, // the whole surface, in cells
    rows:   c.int32_t,
}

// lues's calls, then oket's. Every call takes the api a plugin was handed.
Api :: struct {
    using lues:    abi.Api,
    // The descriptor the plugin's next submit to `doc` lands with, at that submit's generation.
    describe:      proc "c" (api: ^abi.Api, self: abi.Self, doc: abi.Doc_Handle, d: ^Descriptor),
    reveal:        proc "c" (api: ^abi.Api, self: abi.Self, doc: abi.Doc_Handle,
                             lo: c.size_t, hi: c.size_t, at: Reveal),
    // The caret set, landing with the caller's pending submit; with none pending, a bare move.
    cursors:       proc "c" (api: ^abi.Api, self: abi.Self, doc: abi.Doc_Handle,
                             curs: [^]Cursor, n: c.size_t, primary: c.size_t),
    // One view stage per plugin; registering again replaces it.
    register_view: proc "c" (api: ^abi.Api, self: abi.Self, fn: View_Fn),
    world:         proc "c" (api: ^abi.Api, self: abi.Self) -> ^World,
    world_release: proc "c" (api: ^abi.Api, self: abi.Self, w: ^World),
    // Every caret, moved as the kernel's keys move them; queued like `cursors`.
    move:          proc "c" (api: ^abi.Api, self: abi.Self, doc: abi.Doc_Handle, m: Motion,
                             select: c.int32_t),
}

#assert(size_of(Pos) == 16)
#assert(size_of(Cursor) == 48)
#assert(size_of(Range) == 32)
#assert(size_of(Column) == 24)
#assert(size_of(Descriptor) == 64)
#assert(size_of(Side) == 48)
#assert(size_of(View_Out) == 32)
#assert(size_of(Pane) == 32)
#assert(size_of(World) == 24)
#assert(size_of(Api) == size_of(abi.Api) + 7 * size_of(rawptr))

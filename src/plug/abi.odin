package plug

import "core:c"
import "../desc"
import "../input"

// The plugin seam (§7). `oket.h` beside it is these same declarations in C and is what a
// plugin author reads; every struct here asserts its size so the two cannot drift silently.
//
// One tier, `dlopen`'d, in-process, trusted. There is no wire format, no manifest and no
// process boundary — a plugin registers itself by running, which is what `dlopen` is for.
//
// Six messages, and no more (§5):
//
//     register   plugin -> kernel   kinds, commands, bind requests
//     submit     plugin -> kernel   one transaction against a generation
//     reveal     plugin -> kernel   a span, and where to put it in the viewport
//     event      kernel -> plugin   a routed chord, or a generation that moved
//     open       kernel -> plugin   an instance of a kind it registered
//     close      kernel -> plugin   that instance, ending
//
// READS ARE NOT ON THE LIST. Every kernel -> plugin call hands over a `Snapshot` and the
// plugin reads text, the line index, cursors and the descriptor straight out of it, by
// pointer, with no lock and no call back in (§6). Adding a field is a struct field, not a
// message.

API :: 2

// A plugin's own identity, handed back on every call so a plugin needs no state of its own.
// Index plus load generation, packed: a handle kept across a reload resolves to nothing rather
// than to whoever took the slot next.
Self :: distinct u64

// A document, packed the same way and refused the same way. This is store.Id over the wire —
// slot plus seq — so an Id kept across a close is dead, not dangerous.
Doc :: distinct u64

// --- the read view (§6) ---
//
// A snapshot is a piece table, so a "run of text" is what actually exists in memory and a flat
// string is what would have to be manufactured. These mirror txt.Text's arrays exactly and
// point straight into them: the kernel builds the header, never the bytes.

Block :: struct {
    ptr: [^]u8,
    len: c.size_t,
}

Piece :: struct {
    block:   c.ptrdiff_t,
    off:     c.ptrdiff_t,
    len:     c.ptrdiff_t,
    doc_off: c.ptrdiff_t,
}

Seg :: struct {
    first: c.ptrdiff_t,
    at:    c.ptrdiff_t,
    n:     c.ptrdiff_t,
    delta: c.ptrdiff_t,
}

Pos :: struct {
    line: c.ptrdiff_t,
    col:  c.ptrdiff_t, // BYTES into the line
}

Cursor :: struct {
    anchor: Pos,
    head:   Pos,
    goal:   c.ptrdiff_t,
}

Snapshot :: struct {
    desc:     ^Descriptor,
    blocks:   [^]Block,
    starts:   [^]c.ptrdiff_t,
    pieces:   [^]Piece,
    segs:     [^]Seg,
    cursors:  [^]Cursor,
    nblocks:  c.size_t,
    nstarts:  c.size_t,
    npieces:  c.size_t,
    nsegs:    c.size_t,
    ncursors: c.size_t,
    primary:  c.size_t,
    size:     c.size_t, // bytes
    lines:    c.size_t,
    gen:      u64,
    doc:      Doc,
}

// --- the descriptor, read and written through one struct (§5) ---
//
// The enums are desc's own, so the kernel's declaration is the only one on this side. `ctx` is
// absent on purpose: a kind's context is fixed where the kind is registered, so a plugin
// cannot move its documents into another context's keys by publishing a descriptor.

// Names are pointer plus length and are NEVER NUL-terminated: they point straight into the
// kernel's own strings, the same way every string in this seam does.
Column :: struct {
    name:     [^]u8,
    name_len: c.size_t,
    width:    c.int32_t,
    align:    desc.Align,
    _:        [3]u8,
}

Field :: struct {
    name:     [^]u8,
    name_len: c.size_t,
    line:     c.int32_t,
    lo:       c.int32_t,
    hi:       c.int32_t,
    _:        [4]u8,
}

Descriptor :: struct {
    file:      [^]u8,
    file_len:  c.size_t,
    columns:   [^]Column,
    ncolumns:  c.size_t,
    fields:    [^]Field,
    nfields:   c.size_t,
    // One per LINE, dense and in line order, unlike the fields above. A short array leaves the
    // rest of the document at depth 0.
    depth:     [^]c.int32_t,
    ndepth:    c.size_t,
    kind:      input.Kind,
    tab_width: c.int32_t,
    render:    desc.Render,
    wrap:      desc.Wrap,
    numbers:   desc.Numbers,
    selection: desc.Selection,
    follow:    desc.Follow,
    input:     desc.Input,
    mouse:     desc.Mouse,
    editable:  b8,
}

// One replacement, in bytes. A batch is the transaction and one undo entry: the drain takes
// the whole of it or none, against the generation its author read.
Edit :: struct {
    lo:       c.size_t,
    hi:       c.size_t,
    text:     [^]u8,
    text_len: c.size_t,
}

// Where a revealed span lands in the viewport (§11).
Reveal :: enum c.int32_t {
    Nearest, // scroll as little as it takes
    Center,
    Top,
}

// --- kernel -> plugin ---

// What a chord or a moved generation carries. `doc` is the FOCUSED document, not only one this
// plugin opened: that one field is what lets a plugin act on a buffer it did not create (§5).
// `inst` is non-nil only when the focused document is this plugin's own instance.
Event :: enum c.int32_t {
    Chord, // the bind table routed a chord here; `text` is its physical spelling
    Text,  // a rune was typed into this document; `text` is its UTF-8
    Moved, // a document's generation moved
}

At :: struct {
    doc:  Doc,
    inst: rawptr,
    snap: ^Snapshot,
}

// A non-zero return claims the event; zero lets the kernel report it unhandled (§8).
Event_Fn :: #type proc "c" (api: ^Api, self: Self, at: ^At, ev: Event, text: [^]u8, len: c.size_t) -> c.int32_t

// The kernel opened a slot and a document for this kind and hands both over. The return is the
// instance pointer, handed back on every later call and freed by `close`. `args` is what the
// command line carried, never NUL-terminated.
Open_Fn :: #type proc "c" (api: ^Api, self: Self, doc: Doc, args: [^]u8, args_len: c.size_t) -> rawptr

Close_Fn :: #type proc "c" (api: ^Api, self: Self, doc: Doc, inst: rawptr)

// `args` is the rest of the command line. The return is an exit code: 0 advances an `&&`
// chain, anything else stops it — same rule as a shell step.
Command_Fn :: #type proc "c" (api: ^Api, self: Self, at: ^At, args: [^]u8, args_len: c.size_t) -> c.int32_t

Kind_Vt :: struct {
    open:  Open_Fn,
    close: Close_Fn,
    event: Event_Fn,
}

// A kind's registration. `ctx` names the bind context its documents route in — "text",
// "surface" or "terminal" — and "" means surface, which is what a document that is not a text
// field wants.
Kind_Spec :: struct {
    name:     [^]u8,
    name_len: c.size_t,
    ctx:      [^]u8,
    ctx_len:  c.size_t,
    vt:       Kind_Vt,
}

// --- plugin -> kernel ---
//
// C types only, and every call hands the api pointer back, so a plugin carries no state.

Api :: struct {
    version:          u32,

    // register. Three entry points, one message: each appends a ledger record, and unload
    // walks the ledger backwards. A plugin that registers nothing unloads just as cleanly.
    register_kind:    proc "c" (api: ^Api, self: Self, spec: ^Kind_Spec) -> input.Kind,
    register_command: proc "c" (api: ^Api, self: Self, name: [^]u8, name_len: c.size_t,
                                doc: [^]u8, doc_len: c.size_t, fn: Command_Fn),
    // A plugin never CLAIMS a chord (§8): it asks, the row becomes a line in binds.conf, and
    // the file decides from then on.
    request_bind:     proc "c" (api: ^Api, self: Self, ctx: [^]u8, ctx_len: c.size_t,
                                chord: [^]u8, chord_len: c.size_t,
                                line: [^]u8, line_len: c.size_t),

    // submit. One transaction against the generation it was written against; `d` may be nil to
    // leave the descriptor as it stands. Text is copied here, so the plugin's buffer may die
    // the moment this returns. A submit against a document that has moved is dropped whole at
    // the drain — the helper library's retry loop is what a plugin uses instead of writing one.
    submit:           proc "c" (api: ^Api, self: Self, doc: Doc, gen: u64,
                                edits: [^]Edit, nedits: c.size_t, d: ^Descriptor),

    // reveal.
    reveal:           proc "c" (api: ^Api, self: Self, doc: Doc,
                                lo: c.size_t, hi: c.size_t, at: Reveal),

    // Not a message: taking a REFERENCE is a call, reading through it is memory (§6). A
    // snapshot handed with a message is good for that call; a plugin that needs one for longer
    // takes its own here and releases it.
    snapshot:         proc "c" (api: ^Api, self: Self, doc: Doc) -> ^Snapshot,
    release:          proc "c" (api: ^Api, self: Self, snap: ^Snapshot),

    // The echo line. Lives until the next keystroke, same as the kernel's own messages.
    message:          proc "c" (api: ^Api, self: Self, text: [^]u8, text_len: c.size_t),
}

// The one symbol a plugin exports. Non-zero refuses the load, and the ledger reverts whatever
// it managed to register first.
ENTRY :: "oket_main"

Entry_Fn :: #type proc "c" (api: ^Api, self: Self) -> c.int32_t

// The C header declares all of these a second time, because it is a second language. These are
// what stops the two drifting into a silent ABI mismatch; oket.h asserts the same numbers.
#assert(size_of(Block) == 16)
#assert(size_of(Piece) == 32)
#assert(size_of(Seg) == 32)
#assert(size_of(Cursor) == 40)
#assert(size_of(Snapshot) == 128)
#assert(size_of(Column) == 24)
#assert(size_of(Field) == 32)
#assert(size_of(Descriptor) == 80)
#assert(size_of(Edit) == 32)
#assert(size_of(At) == 24)
#assert(size_of(Kind_Spec) == 56)

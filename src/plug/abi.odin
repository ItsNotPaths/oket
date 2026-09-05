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
//     register   plugin -> kernel   kinds, commands, view stages, bind requests
//     submit     plugin -> kernel   one transaction against a generation
//     reveal     plugin -> kernel   a span, and where to put it in the viewport
//     event      kernel -> plugin   a routed chord, a generation that moved, or an I/O job
//     open       kernel -> plugin   an instance of a kind it registered
//     close      kernel -> plugin   that instance, ending
//
// READS ARE NOT ON THE LIST. Every kernel -> plugin call hands over a `Snapshot` and the
// plugin reads text, the line index, cursors and the descriptor straight out of it, by
// pointer, with no lock and no call back in (§6). Adding a field is a struct field, not a
// message.

API :: 9

// A plugin's own identity, handed back on every call so a plugin needs no state of its own.
// Index plus load generation, packed: a handle kept across a reload resolves to nothing rather
// than to whoever took the slot next.
Self :: distinct u64

// A document, packed the same way and refused the same way. This is store.Id over the wire —
// slot plus seq — so an Id kept across a close is dead, not dangerous.
Doc :: distinct u64

// An I/O job — a subprocess, or a watched path (§9). Packed and refused the same way, so a
// handle held past the job's end names nothing rather than whoever spawned next.
Io :: distinct u64

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
    id:     u32,
    _pad:   [4]u8,
}

// A run no cell on screen stands for (a fold), in the document's own coordinates.
Range :: struct {
    lo: Pos,
    hi: Pos,
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
    hidden:   [^]Range,
    nhidden:  c.size_t,
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

// The span is what is DRAWN and `value` is what is ACTED ON; a nil value means the two are the
// same and the span's own bytes fill `<name>` (desc.Field). A row that shows a bare name and
// hands on a whole path is a LINK, and it is the one thing a span alone cannot say.
Field :: struct {
    name:      [^]u8,
    name_len:  c.size_t,
    value:     [^]u8,
    value_len: c.size_t,
    line:      c.int32_t,
    lo:        c.int32_t,
    hi:        c.int32_t,
    _:         [4]u8,
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
    // The cursor that asked for it (Cursor.id), carried onto the caret that replaces its range.
    id:       u32,
    _pad:     [4]u8,
}

// --- the style layer (§5) ---

// A style token, never a colour: the theme decides what it looks like, and a plugin that names
// an RGB value breaks every theme.
//
// An id, not an enum, because a syntax vocabulary is open. The five below are always there; any
// other name is interned through `register_token` and the palette maps it, so the kernel never
// learns what `function.builtin` means.
Token :: u16

// gfx.Token's five, at the ids tokens.odin seeds them at.
Style :: enum Token {
    Fg,
    Bg,
    Accent,
    Dim,
    Alert,
}

// Ids below this are the base vocabulary above; the rest were interned.
TOKEN_BASE :: Token(len(Style))

// The renderer's cell attributes, as bits. gfx.Attr's own order, and the assert in view.odin is
// what keeps the two from drifting.
Attr :: enum u8 {
    Bold      = 1 << 0,
    Italic    = 1 << 1,
    Underline = 1 << 2,
    Reverse   = 1 << 3,
}

// A run of the document, in BYTES, with a style token on it. Not a line and a column: a line
// number is a display convenience, and making it the unit costs every run that crosses a line
// end.
Span :: struct {
    lo:    c.size_t,
    hi:    c.size_t,
    tok:   Token,
    attrs: u8, // Attr's bits
    // Which of the three this run has an opinion about. What it leaves unset is whoever is
    // below it, so an underline over a colour draws as both (§8).
    set:   desc.Chans,
    _:     [4]u8,
}

// One PUBLISHER's range-scoped REPLACE, as it rides a submit. Whatever this plugin held inside
// [lo, hi) is dropped and `spans` takes its place, so a publisher republishing a viewport does
// not make the store grow with the file.
//
// Who is publishing is not a field: the kernel knows which plugin called, and a name it could
// have written down is a name a second plugin could have written down too (§8).
Span_Pub :: struct {
    lo:     c.size_t,
    hi:     c.size_t,
    spans:  [^]Span,
    nspans: c.size_t,
}

// What a submit is, beyond its bytes (§5). The kernel cannot read this off the edits, because
// replacing a whole document and replacing a whole selection are the same two offsets.
//
// REGEN says this text is DERIVED rather than typed, and two rules follow from the one word.
// The carets stay on their rows, because navigation put them there: a tree expanding a
// directory rewrites the rows under it, and point following that splice to the end of the
// document is a tree that cannot be walked. And the undo log is forgotten, because there is
// nothing of the user's in derived text to take back — an undo that walked back into a listing
// its producer has since rebuilt would leave the two describing different documents.
//
// Typing into the same tree to rename a file carries no flag: it collapses and it undoes, the
// way an editor's must.
Submit_Flags :: distinct bit_set[Submit_Flag; u32]
Submit_Flag :: enum u32 {
    Regen = 0,
}

// Where a revealed span lands in the viewport (§11).
Reveal :: enum c.int32_t {
    Nearest, // scroll as little as it takes
    Center,
    Top,
}

// --- the view pipeline (VIEWS.md §5) ---
//
// A stage is handed the PREVIOUS stage's output and returns edits in that space. That is the
// whole of why this is a pipeline and not a fan: a popup positioned against the original would
// land in the wrong place the moment a fold above it deleted lines.
//
// Nothing here reaches the document. A view edit is never submitted, never journalled and never
// saved; it derives what is DRAWN, and motion, undo, find and `:w` go on seeing the original.

// What a stage returns. `edits` are against the text it was handed, sorted by `lo` and disjoint.
// `spans` are over the stage's OWN OUTPUT — the text after these edits — because what a stage
// wants to colour is usually what it just inserted, and that has no original bytes to name.
//
// Both point into the plugin's memory and are copied before the call returns.
View_Out :: struct {
    edits:  [^]Edit,
    nedits: c.size_t,
    spans:  [^]Span,
    nspans: c.size_t,
}

// A non-zero return is the latch, the same meaning `Event_Fn`'s carries for a watcher (§5):
// "not finished, call me again next frame". What it emitted this time is still drawn, so a
// stage too cold for one frame settles over several with no new convention.
View_Fn :: #type proc "c" (api: ^Api, self: Self, at: ^At, out: ^View_Out) -> c.int32_t

// --- the world (§12) ---
//
// A view stage has to size what it inserts, and a popup that cannot ask how wide the pane is
// draws off the edge. Shaped like `Snapshot`: built, flat, taken by a call and read as memory.
// The App is NOT what crosses — freezing a layout would be the worse version of that.

Pane :: struct {
    doc:        Doc,
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

// --- kernel -> plugin ---

// What a chord or a moved generation carries. `doc` is the FOCUSED document — or, for a
// watcher, the document that moved — and not only one this plugin opened: that one field is
// what lets a plugin act on a buffer it did not create (§5). `inst` is non-nil only when the
// document is this plugin's own instance.
Event :: enum c.int32_t {
    Chord,  // the bind table routed a chord here; `text` is its physical spelling
    Text,   // a rune was typed into this document; `text` is its UTF-8
    Moved,  // a document's generation moved, or a watcher has not seen this one yet
    // An I/O job said something (§9). `at.io` names it; `text` is a frame's worth of a
    // child's stdout, or the path a watch saw change. Nothing is held for you: what you do
    // not copy inside this call is gone.
    Io,
    // That job is over, and `at.code` is the exit status. Never sent for a job the plugin
    // closed itself.
    Io_End,
}

At :: struct {
    doc:  Doc,
    inst: rawptr,
    snap: ^Snapshot,
    io:   Io, // the job an .Io or .Io_End names, and zero on every other event
    code: c.int32_t,
    _:    [4]u8,
}

// A non-zero return claims the event; zero lets the kernel report it unhandled (§8).
//
// A WATCHER's return means the other thing, and it is cooperative slicing (§9): non-zero says
// "not finished, call me again next frame" and the kernel does, on the same document, whether or
// not its generation moved again. That is how a cold parse too big for one frame spreads over
// several without a thread, and it needs no seventh message.
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
    // The same rule one file over: a setting the plugin needs is WRITTEN to config.conf if
    // that section has no such key, and from then on the file decides. A view stage asks for
    // its own name in `[<kind>] view` this way, so installing it is copying the `.so` in.
    request_config:   proc "c" (api: ^Api, self: Self, section: [^]u8, section_len: c.size_t,
                                key: [^]u8, key_len: c.size_t,
                                value: [^]u8, value_len: c.size_t),
    // Interns a style-token name and answers its id, the same id for the same name whoever
    // asks: two plugins naming "keyword" get one colour because the palette maps the name.
    // Falls back to Fg's id when the table is full, which draws rather than fails.
    register_token:   proc "c" (api: ^Api, self: Self, name: [^]u8, name_len: c.size_t) -> Token,
    // A plugin that draws nothing asks to be told about documents it did not open: `fn` is
    // called with `.Moved` for every open document this plugin has not seen at its current
    // generation. The ledger reverts it like anything else.
    //
    // Registering again replaces the handler AND forgets what it has been told, so every open
    // document arrives once more. That is how a plugin asks to look again at something the
    // kernel cannot see having changed — a grammar that finished building, a config reloaded.
    register_watch:   proc "c" (api: ^Api, self: Self, fn: Event_Fn),
    // A view stage (§5). ONE per plugin, because the config line that orders the stages ranks
    // them by PLUGIN NAME — the same rule spans follow, where the producer is the layer (§8).
    // Registering again replaces it. A plugin whose name no `view =` line carries is never
    // called, which is what makes installing one a config decision rather than a load order.
    register_view:    proc "c" (api: ^Api, self: Self, fn: View_Fn),

    // submit. One transaction against the generation it was written against; `d` may be nil to
    // leave the descriptor as it stands. Text is copied here, so the plugin's buffer may die
    // the moment this returns. A submit against a document that has moved is dropped whole at
    // the drain — the helper library's retry loop is what a plugin uses instead of writing one.
    // `spans` may be nil to leave every layer as it stands. Edits, descriptor and spans land
    // together at ONE generation, so nothing ever paints a colour against bytes it was not
    // measured over.
    // `flags` is Submit_Flags and 0 for an ordinary edit.
    submit:           proc "c" (api: ^Api, self: Self, doc: Doc, gen: u64,
                                edits: [^]Edit, nedits: c.size_t, d: ^Descriptor,
                                spans: ^Span_Pub, flags: u32),

    // reveal.
    reveal:           proc "c" (api: ^Api, self: Self, doc: Doc,
                                lo: c.size_t, hi: c.size_t, at: Reveal),

    // The cursor set, named exactly (CURSORS.md §4). Copied at the call. It lands WITH the
    // caller's pending transaction, so writes still happen at one point in the frame; a set
    // with nothing pending is a bare move and never bumps the generation.
    cursors:          proc "c" (api: ^Api, self: Self, doc: Doc,
                                curs: [^]Cursor, n: c.size_t, primary: c.size_t),

    // Not a message: taking a REFERENCE is a call, reading through it is memory (§6). A
    // snapshot handed with a message is good for that call; a plugin that needs one for longer
    // takes its own here and releases it.
    snapshot:         proc "c" (api: ^Api, self: Self, doc: Doc) -> ^Snapshot,
    release:          proc "c" (api: ^Api, self: Self, snap: ^Snapshot),

    // The layout, the same way (§12). Cheap, and rebuilt per call: what is on screen changes
    // every frame, so there is nothing here worth holding.
    world:            proc "c" (api: ^Api, self: Self) -> ^World,
    world_release:    proc "c" (api: ^Api, self: Self, w: ^World),

    // The echo line. Lives until the next keystroke, same as the kernel's own messages.
    message:          proc "c" (api: ^Api, self: Self, text: [^]u8, text_len: c.size_t),

    // --- I/O (§9) ---
    //
    // Not a seventh message: what a job says arrives through `event`, routed to the same
    // handler a moved generation would reach. `doc` is what does that routing — a job on one
    // of your own documents reaches its kind, and `doc = 0` reaches your watcher — and it is
    // the only thing the kernel reads it for.
    //
    // Nothing here blocks. One kernel thread does the waiting for every plugin, and a handler
    // is called on the main thread like all the rest, so a plugin still never sees a thread.

    // A child process. `argv` is `nargv` NUL-terminated strings, argv[0] resolved through PATH; the
    // child's STDERR IS INHERITED, because merging it into stdout corrupts a framed protocol
    // and a shell redirect already captures it. Zero when it could not start.
    io_spawn:         proc "c" (api: ^Api, self: Self, doc: Doc, argv: [^]cstring,
                                nargv: c.size_t, cwd: [^]u8, cwd_len: c.size_t) -> Io,
    // Bytes for that child's stdin, queued: the write happens on the kernel's thread, so a
    // full pipe costs a plugin nothing.
    io_write:         proc "c" (api: ^Api, self: Self, io: Io, bytes: [^]u8, len: c.size_t),
    // A path. Its DIRECTORY is what is watched and the name is the filter, because a save by
    // rename leaves a watch on the file holding an inode nobody will write again.
    io_watch:         proc "c" (api: ^Api, self: Self, doc: Doc, path: [^]u8,
                                path_len: c.size_t) -> Io,
    // Ends it: the child's process group is signalled and the watch dropped. Silent — a job
    // you ended is not one you need telling about.
    io_close:         proc "c" (api: ^Api, self: Self, io: Io),
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
#assert(size_of(Cursor) == 48)
#assert(size_of(Range) == 32)
#assert(size_of(Snapshot) == 144)
#assert(size_of(Column) == 24)
#assert(size_of(Field) == 48)
#assert(size_of(Descriptor) == 80)
#assert(size_of(Span) == 24)
#assert(size_of(Span_Pub) == 32)
#assert(size_of(Edit) == 40)
#assert(size_of(At) == 40)
#assert(size_of(View_Out) == 32)
#assert(size_of(Pane) == 32)
#assert(size_of(World) == 24)
#assert(size_of(Kind_Spec) == 56)

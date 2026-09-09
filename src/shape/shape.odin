package shape

// The vocabulary the renderer, the span store and the plugin seam all name. It imports nothing,
// which is the point: `plug` mirrors `txt`'s layouts rather than importing them (§7), but a type
// the seam and the kernel must AGREE on cannot be mirrored safely, and this is where those live.
//
// `oket.h` still declares its own copy, because C always must. That copy is covered by the
// _Static_asserts beside it. A second ODIN copy would be covered by nothing, so there is not
// one: the seam names these types rather than restating them.

// The renderer's cell attributes. An enum of BIT POSITIONS with `Attrs` over it, not an enum of
// masks: a bit_set backed by u8 has the layout `oket.h`'s OKET_ATTR_* values already describe,
// so the seam carries `Attrs` itself and nothing has to transmute a raw byte into it.
Attr :: enum u8 {
    Bold,
    Italic,
    Underline,
    Reverse,
}

Attrs :: bit_set[Attr;u8]

// Style tokens, not colours. A plugin names a token and the theme decides what it looks like; a
// plugin that names an RGB value breaks every theme (§8).
//
// The set stays small on purpose. Every token added is one a theme author has to define and a
// plugin author has to choose between. Ids at or above `len(Style)` were interned by name.
Style :: enum u8 {
    Fg,
    Bg,
    Accent,
    Dim,
    Alert,
}

// --- how a document renders and routes ---
//
// `desc` names all ten and so does the seam, and Odin imports whole packages: living beside the
// Descriptor puts `input`, `rc` and the whole bind table in the seam's graph. `desc` aliases
// them, so these are its names too.

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

// Which of a style run's channels it SETS (§8). A run that says `underline` and nothing about
// colour leaves the colour to whoever is below it, so two publishers at one byte share the cell
// instead of one deleting the other.
//
// Here rather than in the store, which owns the runs, because the SEAM names it too and a
// value set two packages must agree on is named, never copied.
//
// There is no layer enum beside it. WHO published is the ordering, the kernel knows who called,
// and a config line says which of them draws over which (§8, §9).
Chan :: enum u8 {
    Fg,
    Bg,
    Attrs,
}

Chans :: distinct bit_set[Chan; u8]

// --- what a row is made of ---

Column :: struct {
    name:  string,
    width: int,
    align: Align,
}

// A named byte span inside one line, offsets from that line's start. Sorted by line, so a
// lookup is a binary search and a short scan.
//
// THE SPAN IS WHAT IS DRAWN AND `value` IS WHAT IS ACTED ON. Empty, which is the common case,
// means the two are the same and the span's own bytes answer `<name>`. Set, and the line may
// show a bare `browser.c` while `<path>` hands on the whole of where it lives — which is what
// makes a row a LINK and is the one thing a span alone could never say (§5, §14). It is also
// the only way a link in RUNNING TEXT — a path in a compiler error, a file in a diff — can
// carry its target: only a `columns` document has a cell to hide one in.
Field :: struct {
    line:   int,
    name:   string,
    lo, hi: int,
    value:  string,
}

// `oket.h` declares these values a second time, because C must. THIS is what keeps that copy
// honest: a bit_set puts `Attr.X` at bit `int(X)`, so the ordinals below ARE oket.h's
// OKET_ATTR_* shifts, and reordering an enum above is a build error rather than a plugin whose
// bold text comes out italic.
//
// A comment claiming an assert exists is not an assert.
#assert(int(Attr.Bold) == 0) // OKET_ATTR_BOLD      1 << 0
#assert(int(Attr.Italic) == 1) // OKET_ATTR_ITALIC    1 << 1
#assert(int(Attr.Underline) == 2) // OKET_ATTR_UNDERLINE 1 << 2
#assert(int(Attr.Reverse) == 3) // OKET_ATTR_REVERSE   1 << 3
#assert(size_of(Attrs) == 1) // the uint8_t oket_span.attrs is
#assert(int(Style.Fg) == 0) // OKET_TOK_FG
#assert(int(Style.Bg) == 1) // OKET_TOK_BG
#assert(int(Style.Accent) == 2) // OKET_TOK_ACCENT
#assert(int(Style.Dim) == 3) // OKET_TOK_DIM
#assert(int(Style.Alert) == 4) // OKET_TOK_ALERT
#assert(len(Style) == 5) // OKET_TOKEN_BASE

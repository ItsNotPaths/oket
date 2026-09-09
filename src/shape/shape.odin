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

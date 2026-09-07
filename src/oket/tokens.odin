package main

import "core:strings"
import "../gfx"
import "../plug"

// How a name becomes a colour. A plugin names a style TOKEN and never an RGB value, because a
// plugin that names a colour breaks every theme (§5). The table interns names, the palette says
// what an unmapped one looks like, and the RENDERER resolves an id to a colour at draw time —
// the store holds ids, so a theme switch is this table's business and nobody republishes.

// A name a plugin interned, and what the palette said it looks like. Ids below TOKEN_BASE are
// gfx.Token's own five and are seeded here, so `register_token("accent")` is the accent the
// theme already names and not a second one.
Token_Def :: struct {
    name:   string, // owned
    color:  [3]f32,
    themed: bool, // false draws in the theme's Fg, which is what an unmapped name gets
}

// A field a bound mouse chord acts on, and the same field while the pointer or the caret is in
// it. Named here because the KERNEL interns these two, the way a plugin interns its own.
TOKEN_LINK :: "link"
TOKEN_LINK_OVER :: "link.hover"

// An id is 16 bits on the seam, and a plugin interning in a loop must hit a wall rather than
// grow the table forever.
TOKEN_MAX :: 1024

// gfx.Token's five, by name. An enumerated array, so Odin refuses a literal with a member left
// out and the id a name resolves to cannot drift from the id the ABI documents.
@(private = "file", rodata)
BASE_TOKENS := [gfx.Token]string {
    .Fg     = "fg",
    .Bg     = "bg",
    .Accent = "accent",
    .Dim    = "dim",
    .Alert  = "alert",
}

// The id for `name`, the same id for the same name whoever asks: the theme maps names, so two
// plugins naming "keyword" get one colour and neither has to know about the other. Fg's id on
// refusal, because a token that draws in the foreground is a worse answer than the right colour
// and a better one than a failure the caller will not check.
token_intern :: proc(a: ^App, name: string) -> u16 {
    tokens_seed(a)
    if name == "" {
        return u16(gfx.Token.Fg)
    }
    for t, i in a.tokens {
        if t.name == name {
            return u16(i)
        }
    }
    if len(a.tokens) >= TOKEN_MAX {
        return u16(gfx.Token.Fg)
    }
    def := Token_Def {
        name = strings.clone(name),
    }
    def.color, def.themed = theme_lookup(a, name)
    append(&a.tokens, def)
    return u16(len(a.tokens) - 1)
}

// What to paint a token in. The base five come from the theme itself, so switching one moves
// them; the rest carry what theme_lookup last said — at intern, and again at a switch.
token_color :: proc(a: ^App, tok: u16) -> [3]f32 {
    if tok < plug.TOKEN_BASE {
        return a.theme[gfx.Token(tok)]
    }
    if int(tok) < len(a.tokens) && a.tokens[tok].themed {
        return a.tokens[tok].color
    }
    return a.theme[.Fg]
}

// Every interned token resolved, base five included: what `view.draw` reads a style value out
// of. Rebuilt per frame from the one source rather than cached, so it cannot drift from the
// table — a thousand entries at the cap, and most sessions intern a fraction of that.
token_pal :: proc(a: ^App, allocator := context.temp_allocator) -> [][3]f32 {
    pal := make([][3]f32, len(a.tokens), allocator)
    for i in 0 ..< len(pal) {
        pal[i] = token_color(a, u16(i))
    }
    return pal
}

tokens_destroy :: proc(a: ^App) {
    for t in a.tokens {
        delete(t.name)
    }
    delete(a.tokens)
    a.tokens = nil
}

// --- internals ---

// Seeded on first use rather than at startup: a session that loads no plugin interns nothing,
// and a test that touches one document needs no init call of its own.
@(private = "file")
tokens_seed :: proc(a: ^App) {
    if len(a.tokens) > 0 {
        return
    }
    for name in BASE_TOKENS {
        append(&a.tokens, Token_Def{name = strings.clone(name)})
    }
}


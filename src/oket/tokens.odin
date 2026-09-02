package main

import "core:strings"
import "../gfx"
import "../plug"

// How a name becomes a colour. A plugin names a style TOKEN and never an RGB value, because a
// plugin that names a colour breaks every theme (§5). The table interns names, the palette says
// what an unmapped one looks like, and the seam resolves an id to a colour on the way in.

// A name a plugin interned, and what the palette said it looks like. Ids below TOKEN_BASE are
// gfx.Token's own five and are seeded here, so `register_token("accent")` is the accent the
// theme already names and not a second one.
Token_Def :: struct {
    name:   string, // owned
    color:  [3]f32,
    themed: bool, // false draws in the theme's Fg, which is what an unmapped name gets
}

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

// What a name looks like when no theme named it. Only the part before the first dot has to
// match, so `function.builtin` and `function` share a colour until a theme separates them, and
// a vocabulary oket has never heard of still draws.
//
// This is the palette a theme file replaces (§4). Until one lands it is the whole answer.
@(private = "file", rodata)
DEFAULT_SYNTAX := [?]struct {
    name:  string,
    color: [3]f32,
} {
    {"keyword", {0.78, 0.47, 0.87}},
    {"string", {0.60, 0.76, 0.47}},
    {"char", {0.60, 0.76, 0.47}},
    {"escape", {0.60, 0.76, 0.47}},
    {"comment", {0.42, 0.45, 0.50}},
    {"number", {0.82, 0.60, 0.40}},
    {"float", {0.82, 0.60, 0.40}},
    {"boolean", {0.82, 0.60, 0.40}},
    {"constant", {0.82, 0.60, 0.40}},
    {"type", {0.90, 0.75, 0.48}},
    {"constructor", {0.90, 0.75, 0.48}},
    {"function", {0.38, 0.69, 0.94}},
    {"method", {0.38, 0.69, 0.94}},
    {"operator", {0.34, 0.71, 0.76}},
    {"property", {0.55, 0.72, 0.85}},
    {"label", {0.55, 0.72, 0.85}},
    {"diagnostic", {0.95, 0.45, 0.40}},
    {"punctuation", {0.55, 0.57, 0.62}},
    {"bracket", {0.55, 0.57, 0.62}},
    {"delimiter", {0.55, 0.57, 0.62}},
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
    def.color, def.themed = token_palette(name)
    append(&a.tokens, def)
    return u16(len(a.tokens) - 1)
}

// What to paint a token in. The base five come from the theme itself, so switching one moves
// them; the rest carry the colour the palette gave them when they were interned.
token_color :: proc(a: ^App, tok: u16) -> [3]f32 {
    if tok < plug.TOKEN_BASE {
        return a.theme[gfx.Token(tok)]
    }
    if int(tok) < len(a.tokens) && a.tokens[tok].themed {
        return a.tokens[tok].color
    }
    return a.theme[.Fg]
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

// The exact name first, then one dotted segment shorter, and so on: `markup.heading.1` takes
// what `markup.heading` says before what `markup` does. That fallback is what lets a palette of
// twenty keys colour a query of three hundred capture names.
@(private = "file")
token_palette :: proc(name: string) -> (color: [3]f32, themed: bool) {
    key := name
    for {
        for entry in DEFAULT_SYNTAX {
            if entry.name == key {
                return entry.color, true
            }
        }
        dot := strings.last_index_byte(key, '.')
        if dot <= 0 {
            return {}, false
        }
        key = key[:dot]
    }
}

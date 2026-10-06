package main

import "lues:lues"
import "../gfx"
import "../plug"
import "../theme"

// How a name becomes a colour. A plugin names a style TOKEN and never an RGB value, because a
// plugin that names a colour breaks every theme (§5). lues interns the names; this caches what
// the palette says each looks like, and the RENDERER resolves an id at draw time — the store
// holds ids, so a theme switch empties this cache and nobody republishes.

// What the palette said a name looks like, by id.
Token_Def :: struct {
    color:  [3]f32,
    themed: bool, // false draws in the theme's Fg, which is what an unmapped name gets
}

// A field a bound mouse chord acts on, and the same field while the pointer or the caret is in
// it. Named here because the KERNEL interns these two, the way a plugin interns its own.
TOKEN_LINK :: "link"
TOKEN_LINK_OVER :: "link.hover"

// gfx.Token's own five, the base ids: `register_token("accent")` is the accent the theme
// already names and not a second one.
@(rodata)
BASE_TOKENS := [gfx.Token]string {
    .Fg     = "fg",
    .Bg     = "bg",
    .Accent = "accent",
    .Dim    = "dim",
    .Alert  = "alert",
}

// lues answers Fg's id for an empty name or a full table, which draws rather than fails.
token_intern :: proc(a: ^App, name: string) -> u16 {
    return u16(lues.token_intern(a.kernel, name))
}

token_color :: proc(a: ^App, tok: u16) -> [3]f32 {
    if tok < plug.TOKEN_BASE {
        return a.theme[gfx.Token(tok)]
    }
    for len(a.tokens) < len(a.kernel.tokens) {
        def: Token_Def
        def.color, def.themed = theme.lookup(a.scopes, a.kernel.tokens[len(a.tokens)])
        append(&a.tokens, def)
    }
    if int(tok) < len(a.tokens) && a.tokens[tok].themed {
        return a.tokens[tok].color
    }
    return a.theme[.Fg]
}

// Every interned id's colour, for a renderer that resolves per cell. Temp-allocated.
token_pal :: proc(a: ^App, allocator := context.temp_allocator) -> [][3]f32 {
    pal := make([][3]f32, len(a.kernel.tokens), allocator)
    for i in 0 ..< len(pal) {
        pal[i] = token_color(a, u16(i))
    }
    return pal
}

tokens_destroy :: proc(a: ^App) {
    delete(a.tokens)
    a.tokens = nil
}

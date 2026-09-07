package main

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../gfx"
import "../plug"
import "../pty"
import "../toml"

// The theme loader (§4): helix TOML from `<data>/themes/<name>.toml`, read once per switch and
// never written. The span store holds tokens and only the draw resolves (store/spans.odin), so
// applying a theme is a palette swap — the five UI slots, the scope table the token lookup
// reads — and the next frame is the whole repaint. Nothing republishes.

THEME_DEFAULT :: "gruvbox"

// A parent per file, a child's rows over its parent's. Four deep is more than helix ships, and
// a cycle cannot spin.
@(private = "file")
THEME_INHERIT_MAX :: 4

// One scope's say, by channel. A row that speaks neither — `definition = { underline = ... }` —
// is not held at all.
Theme_Entry :: struct {
    fg, bg:         [3]f32,
    has_fg, has_bg: bool,
}

// What a name looks like when no theme names it. Only the part before the last dot has to
// match, so `function.builtin` and `function` share a colour until a theme separates them, and
// a vocabulary oket has never heard of still draws.
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
    // A field a mouse chord would act on, and the same field under the pointer or the caret
    // (routing.odin). Two names rather than one, because `link.hover` would otherwise resolve
    // to `link` by the dot rule and a link would look the same whether or not it was live.
    {"link", {0.38, 0.62, 0.92}},
    {"link.hover", {0.55, 0.79, 1.00}},
    {"punctuation", {0.55, 0.57, 0.62}},
    {"bracket", {0.55, 0.57, 0.62}},
    {"delimiter", {0.55, 0.57, 0.62}},
}

// What the config row means: the empty value is the shipped name (config.odin owns the "").
@(private = "file")
config_theme :: proc(c: ^Config) -> string {
    return c.theme == "" ? THEME_DEFAULT : c.theme
}

// Apply when the config's answer moved. config_sync and `:set` both land here, so a typed row
// and a read one switch the same way — and a name that failed to load is still the applied
// name, so a miss costs one open per switch and not one per frame.
theme_sync :: proc(a: ^App) {
    want := config_theme(&a.config)
    if want == a.theme_on {
        return
    }
    theme_apply(a, want)
}

// What a token name draws as: the loaded theme first, the shipped palette for what it does not
// say, both walked by the dot rule — `markup.heading.1` takes what `markup.heading` says before
// what `markup` does. That fallback is what lets a palette of twenty keys colour a query of
// three hundred capture names.
theme_lookup :: proc(a: ^App, name: string) -> (color: [3]f32, themed: bool) {
    key := name
    for {
        if e, held := a.scopes[key]; held {
            if e.has_fg {
                return e.fg, true
            }
            if e.has_bg {
                return e.bg, true
            }
        }
        dot := strings.last_index_byte(key, '.')
        if dot <= 0 {
            break
        }
        key = key[:dot]
    }
    key = name
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

theme_destroy :: proc(a: ^App) {
    theme_forget(a)
    delete(a.theme_on)
    a.theme_on = {}
}

// --- the switch ---

// The baked five and palette stay under everything the file does not say, so a start with no
// themes directory looks like a start with one (gfx.DEFAULT_THEME).
@(private = "file")
theme_apply :: proc(a: ^App, name: string) {
    delete(a.theme_on)
    a.theme_on = strings.clone(name)
    theme_forget(a)
    a.theme = gfx.DEFAULT_THEME
    theme_read(a, name)
    for &def, i in a.tokens {
        if i >= int(plug.TOKEN_BASE) {
            def.color, def.themed = theme_lookup(a, def.name)
        }
    }
    // What a shell with no SGR draws in, and what an OSC 10/11 query answers.
    for _, tm in a.terms {
        pty.terminal_set_default_colors(&tm.t, a.theme[.Fg], a.theme[.Bg])
    }
}

@(private = "file")
theme_forget :: proc(a: ^App) {
    for key in a.scopes {
        delete(key)
    }
    delete(a.scopes)
    a.scopes = nil
}

// The chain of files into the scope table and the five. The merged palette is built FIRST and
// across the whole chain, because a child's palette names colours for its parent's rows too.
@(private = "file")
theme_read :: proc(a: ^App, name: string) {
    if a.home.data == "" {
        return // a test's App has no directories, and "themes/" relative is somebody's cwd
    }
    roots := make([dynamic]^toml.Table, 0, THEME_INHERIT_MAX, context.temp_allocator)
    if !theme_chain(a, name, &roots, THEME_INHERIT_MAX) {
        return
    }
    pal := make(map[string][3]f32, context.temp_allocator)
    for root in roots {
        if p, held := toml.get_table(root, "palette"); held {
            for key, val in p {
                if s, is_str := val.(string); is_str {
                    if c, ok := hex_color(s); ok {
                        pal[key] = c
                    }
                }
            }
        }
    }
    for root in roots {
        theme_flatten(a, root, pal, "")
    }
    theme_five(a)
}

// Parent first, so a child's rows land over it. A missing or unparseable file is a message and
// whatever the rest of the chain still says — never a fatal.
@(private = "file")
theme_chain :: proc(a: ^App, name: string, roots: ^[dynamic]^toml.Table, depth: int) -> bool {
    if depth == 0 {
        return len(roots) > 0
    }
    path, _ := filepath.join({a.home.data, "themes", fmt.tprintf("%s.toml", name)},
                             context.temp_allocator)
    root, err := toml.parse_file(path, context.temp_allocator)
    if err.type == .Bad_File {
        // The shipped name with no file on disk IS the baked theme, and not worth a message.
        if name != THEME_DEFAULT {
            message_set(a, fmt.tprintf(":theme: no themes/%s.toml", name))
        }
        return len(roots) > 0
    }
    if err.type != .None {
        message_set(a, fmt.tprintf("themes/%s.toml:%d: did not parse", name, err.line))
        return len(roots) > 0
    }
    if parent, held := toml.get_string(root, "inherits"); held {
        theme_chain(a, parent, roots, depth - 1)
    }
    append(roots, root)
    return true
}

// One root's rows. A table is a STYLE when it speaks any style key and a NAMESPACE otherwise —
// both spellings arrive, because `"ui.text" = {}` is one flat key while `ui.text = "#fff"` is a
// table a dotted key built.
@(private = "file")
theme_flatten :: proc(a: ^App, root: ^toml.Table, pal: map[string][3]f32, prefix: string) {
    for key, val in root {
        if prefix == "" && (key == "palette" || key == "inherits") {
            continue
        }
        name := prefix == "" ? key : fmt.tprintf("%s.%s", prefix, key)
        entry: Theme_Entry
        #partial switch v in val {
        case string:
            entry.fg, entry.has_fg = theme_color(pal, v)
        case ^toml.Table:
            style: bool
            if entry, style = style_entry(v, pal); !style {
                theme_flatten(a, v, pal, name)
                continue
            }
        }
        if !entry.has_fg && !entry.has_bg {
            continue
        }
        if name in a.scopes {
            a.scopes[name] = entry // the key on file is the one already owned
        } else {
            a.scopes[strings.clone(name)] = entry
        }
    }
}

// Speaking any style key is what MAKES it a style; fg and bg are the two channels kept.
@(private = "file")
style_entry :: proc(t: ^toml.Table, pal: map[string][3]f32) -> (entry: Theme_Entry, style: bool) {
    style = "fg" in t^ || "bg" in t^ || "modifiers" in t^ || "underline" in t^
    if !style {
        return
    }
    if s, held := toml.get_string(t, "fg"); held {
        entry.fg, entry.has_fg = theme_color(pal, s)
    }
    if s, held := toml.get_string(t, "bg"); held {
        entry.bg, entry.has_bg = theme_color(pal, s)
    }
    return
}

// The five UI slots, each from the key gfx.DEFAULT_THEME's comment names, each keeping its
// baked value where the file is silent. Accent is the primary cursor's BLOCK, which helix says
// as a background.
@(private = "file")
theme_five :: proc(a: ^App) {
    if c, held := scope_fg(a, "ui.text"); held {
        a.theme[.Fg] = c
    }
    if c, held := scope_bg(a, "ui.background"); held {
        a.theme[.Bg] = c
    }
    if c, held := scope_bg(a, "ui.cursor.primary"); held {
        a.theme[.Accent] = c
    } else if c, held := scope_bg(a, "ui.cursor"); held {
        a.theme[.Accent] = c
    }
    if c, held := scope_fg(a, "ui.linenr"); held {
        a.theme[.Dim] = c
    }
    if c, held := scope_fg(a, "error"); held {
        a.theme[.Alert] = c
    }
}

// One exact scope's one channel; an absent key is a zero entry, which speaks neither.
@(private = "file")
scope_fg :: proc(a: ^App, key: string) -> ([3]f32, bool) {
    e := a.scopes[key]
    return e.fg, e.has_fg
}

@(private = "file")
scope_bg :: proc(a: ^App, key: string) -> ([3]f32, bool) {
    e := a.scopes[key]
    return e.bg, e.has_bg
}

@(private = "file")
theme_color :: proc(pal: map[string][3]f32, s: string) -> ([3]f32, bool) {
    if c, held := pal[s]; held {
        return c, true
    }
    return hex_color(s)
}

// `#rrggbb`. Anything else — an ANSI name, a typo — colours nothing rather than guessing.
@(private = "file")
hex_color :: proc(s: string) -> ([3]f32, bool) {
    if len(s) != 7 || s[0] != '#' {
        return {}, false
    }
    n, ok := strconv.parse_u64_of_base(s[1:], 16)
    if !ok {
        return {}, false
    }
    return {f32(n >> 16 & 255) / 255, f32(n >> 8 & 255) / 255, f32(n & 255) / 255}, true
}

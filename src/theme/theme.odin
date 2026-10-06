package theme

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../gfx"
import "../toml"

// The theme loader (§4): helix TOML from `<dir>/themes/<name>.toml`, read once per switch and
// never written. The span store holds tokens and only the draw resolves (lues docs/spans.odin), so
// applying a theme is a palette swap — the five UI slots, the scope table the token lookup
// reads — and the next frame is the whole repaint. Nothing republishes.

DEFAULT :: "gruvbox"

// The default ships INSIDE the binary, so a start with no themes directory is a start with the
// whole theme and not only the five UI slots gfx.DEFAULT_THEME bakes. The five and this file
// are the same palette; a test asserts they have not drifted (theme_test.odin).
@(private = "file", rodata)
BAKED := #load("../../themes/gruvbox.toml")

// A parent per file, a child's rows over its parent's. Four deep is more than helix ships, and
// a cycle cannot spin.
@(private = "file")
INHERIT_MAX :: 4

// One scope's say, by channel. A row that speaks neither — `definition = { underline = ... }` —
// is not held at all.
Entry :: struct {
    fg, bg:         [3]f32,
    has_fg, has_bg: bool,
}

// What a name looks like when no theme names it. Only the part before the last dot has to
// match, so `function.builtin` and `function` share a colour until a theme separates them, and
// a vocabulary nobody has heard of still draws.
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
    // A field a mouse chord would act on, and the same field under the pointer or the caret.
    // Two names rather than one, because `link.hover` would otherwise resolve to `link` by the
    // dot rule and a link would look the same whether or not it was live.
    {"link", {0.38, 0.62, 0.92}},
    {"link.hover", {0.55, 0.79, 1.00}},
    {"punctuation", {0.55, 0.57, 0.62}},
    {"bracket", {0.55, 0.57, 0.62}},
    {"delimiter", {0.55, 0.57, 0.62}},
}

// The theme `name` and its parents into `scopes`, which is emptied first, and the five UI slots
// it says. The baked five stay under everything the files do not say. `problem` is the last
// file that failed, temp-allocated; what the rest of the chain said still loads.
load :: proc(scopes: ^map[string]Entry, dir, name: string) -> (ui: gfx.Theme, problem: string) {
    forget(scopes)
    ui = gfx.DEFAULT_THEME
    roots := make([dynamic]^toml.Table, 0, INHERIT_MAX, context.temp_allocator)
    if !read_chain(dir, name, &roots, INHERIT_MAX, &problem) {
        return
    }
    pal := palette(roots[:])
    for root in roots {
        flatten(scopes, root, pal, "")
    }
    five(scopes^, &ui)
    return
}

// What a token name draws as: the loaded scopes first, the shipped palette for what they do not
// say, both walked by the dot rule — `markup.heading.1` takes what `markup.heading` says before
// what `markup` does. That fallback is what lets a palette of twenty keys colour a query of
// three hundred capture names.
lookup :: proc(scopes: map[string]Entry, name: string) -> (color: [3]f32, themed: bool) {
    key := name
    for {
        if e, held := scopes[key]; held {
            if e.has_fg {
                return e.fg, true
            }
            if e.has_bg {
                return e.bg, true
            }
        }
        key = parent_key(key) or_break
    }
    key = name
    for {
        for entry in DEFAULT_SYNTAX {
            if entry.name == key {
                return entry.color, true
            }
        }
        key = parent_key(key) or_return
    }
}

forget :: proc(scopes: ^map[string]Entry) {
    for key in scopes {
        delete(key)
    }
    delete(scopes^)
    scopes^ = nil
}

// Merged FIRST and across the whole chain, because a child's palette names colours for its
// parent's rows too.
@(private = "file")
palette :: proc(roots: []^toml.Table) -> map[string][3]f32 {
    pal := make(map[string][3]f32, context.temp_allocator)
    for root in roots {
        p := toml.get_table(root, "palette") or_continue
        for key, val in p {
            s := val.(string) or_continue
            if c, ok := hex_color(s); ok {
                pal[key] = c
            }
        }
    }
    return pal
}

@(private = "file")
parent_key :: proc(key: string) -> (string, bool) {
    dot := strings.last_index_byte(key, '.')
    return key[:max(dot, 0)], dot > 0
}

// Parent first, so a child's rows land over it. A missing or unparseable file is a problem and
// whatever the rest of the chain still says — never a fatal.
@(private = "file")
read_chain :: proc(dir, name: string, roots: ^[dynamic]^toml.Table, depth: int,
                   problem: ^string) -> bool {
    if depth == 0 {
        return len(roots) > 0
    }
    path, _ := filepath.join({dir, "themes", fmt.tprintf("%s.toml", name)},
                             context.temp_allocator)
    root, err := toml.parse_file(path, context.temp_allocator)
    switch {
    case err.type == .Bad_File && name == DEFAULT:
        // The default with no file on disk is the baked copy, and not worth a problem. A file
        // you drop under that name still wins: this is the miss, not the first try.
        root, err = toml.parse_data(BAKED, "gruvbox.toml", context.temp_allocator)
        if err.type != .None {
            return len(roots) > 0
        }
    case err.type == .Bad_File:
        problem^ = fmt.tprintf(":theme: no themes/%s.toml", name)
        return len(roots) > 0
    case err.type != .None:
        problem^ = fmt.tprintf("themes/%s.toml:%d: did not parse", name, err.line)
        return len(roots) > 0
    }
    if parent, held := toml.get_string(root, "inherits"); held {
        read_chain(dir, parent, roots, depth - 1, problem)
    }
    append(roots, root)
    return true
}

// One root's rows. A table is a STYLE when it speaks any style key and a NAMESPACE otherwise —
// both spellings arrive, because `"ui.text" = {}` is one flat key while `ui.text = "#fff"` is a
// table a dotted key built.
@(private = "file")
flatten :: proc(scopes: ^map[string]Entry, root: ^toml.Table, pal: map[string][3]f32,
                prefix: string) {
    for key, val in root {
        if prefix == "" && (key == "palette" || key == "inherits") {
            continue
        }
        name := prefix == "" ? key : fmt.tprintf("%s.%s", prefix, key)
        entry: Entry
        #partial switch v in val {
        case string:
            entry.fg, entry.has_fg = color(pal, v)
        case ^toml.Table:
            style: bool
            if entry, style = style_entry(v, pal); !style {
                flatten(scopes, v, pal, name)
                continue
            }
        }
        if !entry.has_fg && !entry.has_bg {
            continue
        }
        if name in scopes {
            scopes[name] = entry // the key on file is the one already owned
        } else {
            scopes[strings.clone(name)] = entry
        }
    }
}

// Speaking any style key is what MAKES it a style; fg and bg are the two channels kept.
@(private = "file")
style_entry :: proc(t: ^toml.Table, pal: map[string][3]f32) -> (entry: Entry, style: bool) {
    style = "fg" in t^ || "bg" in t^ || "modifiers" in t^ || "underline" in t^
    if !style {
        return
    }
    if s, held := toml.get_string(t, "fg"); held {
        entry.fg, entry.has_fg = color(pal, s)
    }
    if s, held := toml.get_string(t, "bg"); held {
        entry.bg, entry.has_bg = color(pal, s)
    }
    return
}

// The five UI slots, each from the key gfx.DEFAULT_THEME's comment names, each keeping its
// baked value where the file is silent. Accent is the primary cursor's BLOCK, which helix says
// as a background.
@(private = "file")
five :: proc(scopes: map[string]Entry, ui: ^gfx.Theme) {
    if e := scopes["ui.text"]; e.has_fg {
        ui[.Fg] = e.fg
    }
    if e := scopes["ui.background"]; e.has_bg {
        ui[.Bg] = e.bg
    }
    if e := scopes["ui.cursor.primary"]; e.has_bg {
        ui[.Accent] = e.bg
    } else if e := scopes["ui.cursor"]; e.has_bg {
        ui[.Accent] = e.bg
    }
    if e := scopes["ui.linenr"]; e.has_fg {
        ui[.Dim] = e.fg
    }
    if e := scopes["error"]; e.has_fg {
        ui[.Alert] = e.fg
    }
}

@(private = "file")
color :: proc(pal: map[string][3]f32, s: string) -> ([3]f32, bool) {
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

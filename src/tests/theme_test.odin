package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../gfx"
import app "../oket"

// The theme loader (§4): helix TOML, read once per switch. The five UI slots, the token
// recolour, inherits, and the fallbacks — the switch itself is a palette swap, which
// spans_test's retint gate already holds to.

// The same arithmetic hex_color does, so an expectation is exact and never a float tolerance.
@(private = "file")
hex :: proc(n: u32) -> [3]f32 {
    return {f32(n >> 16 & 255) / 255, f32(n >> 8 & 255) / 255, f32(n & 255) / 255}
}

@(private = "file")
theme_home :: proc(t: ^testing.T, name: string) -> (a: app.App, dir: string, ok: bool) {
    dir = scratch(t, name) or_return
    a = bare_app() or_return
    app.home_set(&a.home, dir)
    themes, _ := filepath.join({dir, "themes"}, context.temp_allocator)
    os.make_directory(themes)
    return a, dir, true
}

@(private = "file")
theme_write :: proc(dir, name, body: string) {
    path, _ := filepath.join({dir, "themes", fmt.tprintf("%s.toml", name)},
                             context.temp_allocator)
    _ = os.write_entire_file(path, transmute([]u8)body)
}

// THE GATE. The file this repo ships parses, fills the five, and recolours a token somebody
// interned before the switch — which is the whole loader working over a real helix theme.
@(test)
the_shipped_theme_reads_and_retints :: proc(t: ^testing.T) {
    a, dir, ok := theme_home(t, "oket-theme-shipped")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer app.home_destroy(&a.home)
    defer close_app(&a)

    raw, err := os.read_entire_file("themes/gruvbox.toml", context.temp_allocator)
    if !testing.expect(t, err == nil, "the repo's themes/gruvbox.toml is missing") {
        return
    }
    theme_write(dir, "gruvbox", string(raw))
    key := app.token_intern(&a, "keyword") // before the switch: the switch must recolour it

    app.theme_sync(&a) // the config's default name is the shipped one

    testing.expect_value(t, a.theme[.Fg], hex(0xebdbb2)) // ui.text -> fg1
    testing.expect_value(t, a.theme[.Bg], hex(0x282828)) // ui.background -> bg0
    testing.expect_value(t, a.theme[.Accent], hex(0xbdae93)) // ui.cursor.primary's BLOCK, fg3
    testing.expect_value(t, a.theme[.Dim], hex(0x665c54)) // ui.linenr -> bg3
    testing.expect_value(t, a.theme[.Alert], hex(0xfb4934)) // error -> red1
    testing.expect_value(t, app.token_color(&a, key), hex(0xfb4934)) // keyword -> red1
    testing.expect_value(t, a.message, "")
}

// A name with no file is the baked theme and a message; the DEFAULT name with no file is the
// baked theme and silence, because a start with no themes directory is not a mistake.
@(test)
a_missing_theme_is_a_message_and_the_baked_five :: proc(t: ^testing.T) {
    a, dir, ok := theme_home(t, "oket-theme-missing")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer app.home_destroy(&a.home)
    defer close_app(&a)

    app.theme_sync(&a)
    testing.expect_value(t, a.theme, gfx.Theme(gfx.DEFAULT_THEME))
    testing.expect_value(t, a.message, "")

    testing.expect(t, app.config_set_line(&a.config, "theme", "name", "nope"))
    app.theme_sync(&a)
    testing.expect_value(t, a.theme, gfx.Theme(gfx.DEFAULT_THEME))
    testing.expect(t, strings.contains(a.message, "nope"), "the miss was silent")
}

// `inherits`: the parent's rows land under the child's, and the PALETTE merges child-last —
// a child that renames one colour recolours the parent rows written against it.
@(test)
inherits_merges_parent_rows_and_palettes :: proc(t: ^testing.T) {
    a, dir, ok := theme_home(t, "oket-theme-inherits")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer app.home_destroy(&a.home)
    defer close_app(&a)

    theme_write(dir, "parent", `
"keyword" = { fg = "brand" }
"string" = { fg = "brand" }
[palette]
brand = "#111111"
`)
    theme_write(dir, "child", `
inherits = "parent"
"keyword" = { fg = "#444444" }
[palette]
brand = "#333333"
`)
    testing.expect(t, app.config_set_line(&a.config, "theme", "name", "child"))
    app.theme_sync(&a)

    kw, kw_themed := app.theme_lookup(&a, "keyword")
    st, st_themed := app.theme_lookup(&a, "string")
    testing.expect(t, kw_themed && st_themed)
    testing.expect_value(t, kw, hex(0x444444)) // the child's own row wins
    testing.expect_value(t, st, hex(0x333333)) // the parent's row, through the child's palette
}

// Switching back unloads: the scopes go, the five return to the baked values, and a token the
// loaded theme had recoloured re-derives to the shipped palette's answer.
@(test)
a_switch_back_restores_the_baked_palette :: proc(t: ^testing.T) {
    a, dir, ok := theme_home(t, "oket-theme-back")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer app.home_destroy(&a.home)
    defer close_app(&a)

    theme_write(dir, "loud", `
"keyword" = "#010203"
"ui.background" = { bg = "#040506" }
`)
    key := app.token_intern(&a, "keyword")
    testing.expect(t, app.config_set_line(&a.config, "theme", "name", "loud"))
    app.theme_sync(&a)
    testing.expect_value(t, a.theme[.Bg], hex(0x040506))
    testing.expect_value(t, app.token_color(&a, key), hex(0x010203))

    testing.expect(t, app.config_set_line(&a.config, "theme", "name", "gruvbox"))
    app.theme_sync(&a) // no gruvbox.toml in this scratch: the baked copy IS the answer
    testing.expect_value(t, a.theme, gfx.Theme(gfx.DEFAULT_THEME))
    // The whole file is baked, not only the five, so the scope table comes back with them.
    testing.expect_value(t, app.token_color(&a, key), hex(0xfb4934))
}

// The other spelling of a dotted key: a `[ui.cursor]` header is a table the flatten recurses
// into, landing on the same name the flat quoted key spells — and with no `ui.cursor.primary`,
// Accent takes it through the fallback.
@(test)
a_table_header_spells_the_same_scope :: proc(t: ^testing.T) {
    a, dir, ok := theme_home(t, "oket-theme-header")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer app.home_destroy(&a.home)
    defer close_app(&a)

    theme_write(dir, "nested", `
[ui.cursor]
bg = "#0a0b0c"
`)
    testing.expect(t, app.config_set_line(&a.config, "theme", "name", "nested"))
    app.theme_sync(&a)
    testing.expect_value(t, a.theme[.Accent], hex(0x0a0b0c))
}

// A file that does not parse is a message with its line, the baked five, and no crash.
@(test)
an_unparseable_theme_is_a_message_and_the_baked_five :: proc(t: ^testing.T) {
    a, dir, ok := theme_home(t, "oket-theme-broke")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer app.home_destroy(&a.home)
    defer close_app(&a)

    theme_write(dir, "broke", "[unclosed\n")
    testing.expect(t, app.config_set_line(&a.config, "theme", "name", "broke"))
    app.theme_sync(&a)
    testing.expect_value(t, a.theme, gfx.Theme(gfx.DEFAULT_THEME))
    testing.expect(t, strings.contains(a.message, "did not parse"), "the bad file was silent")
}

// The dot rule reaches through a loaded theme, and what a theme does not say falls back to the
// shipped palette rather than drawing plain: three scopes must not uncolour a JSON file.
@(test)
a_partial_theme_keeps_the_shipped_fallback :: proc(t: ^testing.T) {
    a, dir, ok := theme_home(t, "oket-theme-partial")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer app.home_destroy(&a.home)
    defer close_app(&a)

    theme_write(dir, "tiny", `
"function" = "#0a0b0c"
`)
    testing.expect(t, app.config_set_line(&a.config, "theme", "name", "tiny"))
    app.theme_sync(&a)

    fb, _ := app.theme_lookup(&a, "function.builtin") // the dot rule, into the loaded scopes
    testing.expect_value(t, fb, hex(0x0a0b0c))
    st, themed := app.theme_lookup(&a, "string") // unsaid, so the shipped palette answers
    testing.expect(t, themed, "an unsaid scope drew plain")
    testing.expect_value(t, st, [3]f32{0.60, 0.76, 0.47})
}

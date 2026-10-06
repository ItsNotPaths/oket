package main

import "core:strings"
import "../gfx"
import "../pty"
import "../theme"

// The theme's host (src/theme): which name the config wants, and what a switch must redo here.

// Named here because App's own `theme` field hides the package inside the struct.
Theme_Entry :: theme.Entry

// What the config row means: the empty value is the shipped name (config.odin owns the "").
@(private = "file")
config_theme :: proc(c: ^Config) -> string {
    return c.theme == "" ? theme.DEFAULT : c.theme
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

theme_destroy :: proc(a: ^App) {
    theme.forget(&a.scopes)
    delete(a.theme_on)
    a.theme_on = {}
}

@(private = "file")
theme_apply :: proc(a: ^App, name: string) {
    delete(a.theme_on)
    a.theme_on = strings.clone(name)
    if a.home.data == "" {
        // A test's App has no directories, and "themes/" relative is somebody's cwd.
        theme.forget(&a.scopes)
        a.theme = gfx.DEFAULT_THEME
    } else {
        problem: string
        a.theme, problem = theme.load(&a.scopes, a.home.data, name)
        if problem != "" {
            message_set(a, problem)
        }
    }
    clear(&a.tokens) // token_color fills it again under this palette
    // What a shell with no SGR draws in, and what an OSC 10/11 query answers.
    for _, tm in a.terms {
        pty.terminal_set_default_colors(&tm.t, a.theme[.Fg], a.theme[.Bg])
    }
}

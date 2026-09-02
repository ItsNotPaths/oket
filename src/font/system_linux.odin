#+build linux
package font

import "core:fmt"

// fontconfig's `monospace` alias IS the system answer on Linux: it resolves through the
// user's own rules.
system_fixed :: proc(allocator := context.allocator) -> (Found, bool) {
    return fc_match("monospace", allocator)
}

// A family name from the config to a file on disk. Exact, not a match: a config that names
// a font must never silently get a different one, and not installed reports as such.
resolve :: proc(family: string, allocator := context.allocator) -> (Found, bool) {
    return fc_list_exact(family, allocator)
}

// Who on this machine has a glyph for `r`. fontconfig ALWAYS returns a match, so its answer
// is a candidate and `covers` decides. A symbols-only face is asked for first, being the
// leaner answer; any face carrying the glyph will do if it is absent.
find_covering :: proc(r: rune, allocator := context.allocator) -> (Found, bool) {
    patterns := [?]string {
        fmt.tprintf("Symbols Nerd Font Mono:charset=%x", i32(r)),
        fmt.tprintf(":charset=%x", i32(r)),
    }
    for p in patterns {
        if f, ok := fc_match(p, allocator); ok && covers(f.path, r) {
            return f, true
        }
    }
    return {}, false
}

font_backend :: proc() -> string {
    return fc_available() ? "fontconfig" : "none"
}

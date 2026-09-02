package tests

import "core:os"
import "core:strings"
import "core:testing"
import "../font"

// Every test here is lenient about a machine with no fontconfig and no fonts, the way an
// offline checkout has to be. What it will not tolerate is a WRONG answer.

@(test)
system_fixed_font_is_real :: proc(t: ^testing.T) {
    f, ok := font.system_fixed()
    if !ok {
        testing.expect_value(t, font.font_backend(), "none") // no backend is the only excuse
        return
    }
    defer delete(f.family);defer delete(f.path)

    testing.expect(t, f.family != "", "matched a font with no family name")
    testing.expect(t, os.exists(f.path), "the matched font file does not exist")
    testing.expect(t, font.covers(f.path, 'A'), "the system fixed font has no 'A'")
}

// The probe has to say no as reliably as it says yes, or the stack fills up with entries that
// contribute nothing.
@(test)
covers_rejects_what_is_missing :: proc(t: ^testing.T) {
    testing.expect(t, !font.covers("/nonexistent/font.ttf", 'A'))
    testing.expect(t, !font.covers("/etc/hostname", 'A'), "a non-font file passed as a font")

    f, ok := font.resolve("Noto Sans Mono")
    if !ok {
        return // not installed here
    }
    defer delete(f.family);defer delete(f.path)
    testing.expect(t, font.covers(f.path, 'A'))
    // A plain text face has no powerline glyphs. This is the setup that needs a second entry.
    testing.expect(t, !font.covers(f.path, font.ICON_PROBE), "a plain face claims powerline glyphs")
}

// resolve is EXACT: a binding="strong" user rule (the shape omarchy ships) rewrites an
// explicitly named family under FcFontMatch. Caught on a real machine, kept here.
@(test)
resolve_does_not_substitute :: proc(t: ^testing.T) {
    f, ok := font.resolve("Noto Sans Mono")
    if !ok {
        return
    }
    defer delete(f.family);defer delete(f.path)
    testing.expectf(t, strings.contains(f.family, "Noto Sans Mono"),
                    "asked for Noto Sans Mono, resolve gave %s", f.family)

    // And a font that is not installed says so rather than handing back a substitute.
    if g, found := font.resolve("Definitely Not An Installed Font"); found {
        defer delete(g.family);defer delete(g.path)
        testing.expectf(t, false, "a made-up family resolved to %s", g.family)
    }
}

// The stack an explicit plain primary needs: itself, plus icons, and no entry that the primary
// already covered.
@(test)
grab_extends_a_plain_primary :: proc(t: ^testing.T) {
    probe, installed := font.resolve("Noto Sans Mono")
    if !installed {
        return
    }
    delete(probe.family);delete(probe.path)

    stack, ok := font.grab("Noto Sans Mono")
    testing.expect(t, ok)
    defer delete(stack)
    defer for e in stack {delete(e.family);delete(e.path)}

    has_icons := false
    for e in stack {
        if e.reason == .Icons {
            has_icons = true
            testing.expect(t, font.covers(e.path, font.ICON_PROBE))
        }
    }
    // Only assert the entry exists if the machine has anything that could fill it.
    icons, found := font.find_covering(font.ICON_PROBE)
    if found {
        delete(icons.family);delete(icons.path)
        testing.expect(t, has_icons, "a plain primary got no icon face beside it")
    }
}

// The monospace + symbols setup, which is the one that needs the stack to work at all.
@(test)
find_covering_verifies_its_candidate :: proc(t: ^testing.T) {
    f, ok := font.find_covering(font.ICON_PROBE)
    if !ok {
        return // nothing installed has powerline glyphs
    }
    defer delete(f.family);defer delete(f.path)
    testing.expect(t, font.covers(f.path, font.ICON_PROBE),
                   "find_covering returned a face without the glyph it was asked for")
}

// The whole point: what grab writes into the config is a stack that actually covers things.
@(test)
grab_builds_a_covering_stack :: proc(t: ^testing.T) {
    stack, ok := font.grab()
    if !ok {
        return
    }
    defer delete(stack)
    defer for e in stack {delete(e.family);delete(e.path)}

    testing.expect(t, len(stack) >= 1)
    testing.expect_value(t, stack[0].reason, font.Reason.Primary)

    for e in stack {
        testing.expectf(t, os.exists(e.path), "%s: %s does not exist", e.family, e.path)
        switch e.reason {
        case .Primary:
            testing.expect(t, font.covers(e.path, 'A'))
        case .Icons:
            testing.expect(t, font.covers(e.path, font.ICON_PROBE))
        case .CJK:
            testing.expect(t, font.covers(e.path, font.CJK_PROBE))
        }
    }

    // No entry earns its place by covering nothing the primary was missing.
    for e in stack[1:] {
        probe := e.reason == .Icons ? font.ICON_PROBE : font.CJK_PROBE
        testing.expectf(t, !font.covers(stack[0].path, probe),
                        "%s was added for a glyph the primary already has", e.family)
    }
}

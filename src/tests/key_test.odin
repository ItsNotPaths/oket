package tests

import "core:testing"
import "../input"

// A fake layout: the machine running tests has no window, so the resolver and the display
// callback are stand-ins, which is exactly why they are callbacks.
@(private = "file")
qwerty_j :: proc(name: string) -> (input.Code, bool) {
    if name == "j" {
        code, _ := input.key_code("AC07")
        return code, true
    }
    return 0, false
}

@(test)
key_names_round_trip :: proc(t: ^testing.T) {
    for e in input.KEY_NAMES {
        code, ok := input.key_code(e.name)
        testing.expectf(t, ok && code == e.code, "%s does not round-trip", e.name)
    }
}

@(test)
key_alias_resolves_to_primary :: proc(t: ^testing.T) {
    alias, ok := input.key_code("AC12")
    testing.expect(t, ok)
    primary, _ := input.key_code("BKSL")
    testing.expect_value(t, alias, primary)
}

@(test)
chord_parse_spellings :: proc(t: ^testing.T) {
    ac07, _ := input.key_code("AC07")

    c, ok := input.chord_parse("ctrl+alt+@AC07", nil)
    testing.expect(t, ok)
    testing.expect_value(t, c, input.Chord{ac07, {.Ctrl, .Alt}})

    c, ok = input.chord_parse("alt+j", qwerty_j)
    testing.expect(t, ok)
    testing.expect_value(t, c, input.Chord{ac07, {.Alt}})

    // A label spelling, for keys no layout names.
    f1, _ := input.key_code("FK01")
    c, ok = input.chord_parse("shift+f1", nil)
    testing.expect(t, ok)
    testing.expect_value(t, c, input.Chord{f1, {.Shift}})

    // A numeric physical spelling reaches codes the name table does not cover.
    c, ok = input.chord_parse("@300", nil)
    testing.expect(t, ok)
    testing.expect_value(t, c.code, input.Code(300))

    // A trailing '+' is the key itself, not a separator.
    kpad, _ := input.key_code("KPAD")
    c, ok = input.chord_parse("ctrl+kp+", nil)
    testing.expect(t, ok)
    testing.expect_value(t, c, input.Chord{kpad, {.Ctrl}})

    _, ok = input.chord_parse("bogus+j", qwerty_j)
    testing.expect(t, !ok)
    _, ok = input.chord_parse("ctrl+", qwerty_j)
    testing.expect(t, !ok)
    _, ok = input.chord_parse("", qwerty_j)
    testing.expect(t, !ok)
}

@(test)
chord_physical_parses_back :: proc(t: ^testing.T) {
    for e in input.KEY_NAMES {
        chord := input.Chord{e.code, {.Alt}}
        spelling := input.chord_physical(chord)
        defer delete(spelling)
        parsed, ok := input.chord_parse(spelling, nil)
        testing.expectf(t, ok && parsed == chord, "%s does not parse back", spelling)
    }
}

@(test)
chord_format_falls_back :: proc(t: ^testing.T) {
    ac07, _ := input.key_code("AC07")
    esc, _ := input.key_code("ESC")

    layout :: proc(code: input.Code) -> string {
        return input.key_name(code) == "AC07" ? "j" : ""
    }

    s := input.chord_format(input.Chord{ac07, {.Ctrl}}, layout)
    testing.expect_value(t, s, "ctrl+j")
    delete(s)

    // No layout glyph: the label table answers.
    s = input.chord_format(input.Chord{esc, {}}, layout)
    testing.expect_value(t, s, "esc")
    delete(s)

    // No glyph and no label: the physical spelling is the floor.
    s = input.chord_format(input.Chord{300, {.Alt}}, layout)
    testing.expect_value(t, s, "alt+@300")
    delete(s)
}

@(test)
modifier_codes_are_modifiers :: proc(t: ^testing.T) {
    for name in ([?]string{"LFSH", "RTSH", "LCTL", "RCTL", "LALT", "RALT", "LWIN", "RWIN"}) {
        code, ok := input.key_code(name)
        testing.expect(t, ok)
        testing.expectf(t, input.code_is_modifier(code), "%s is a modifier", name)
    }
    esc, _ := input.key_code("ESC")
    testing.expect(t, !input.code_is_modifier(esc))
}

@(test)
key_labels_name_real_keys :: proc(t: ^testing.T) {
    for e in input.KEY_LABELS {
        _, ok := input.key_code(e.name)
        testing.expectf(t, ok, "label %s names %s, which is not in the table", e.label, e.name)
    }
}

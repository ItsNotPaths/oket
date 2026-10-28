package tests

import "core:strings"
import "core:testing"
import "../input"
import app "../oket"

// binds.conf groups (§8): a header lists the groups a section walks after its own rows, global
// is always last, and a group's own list is never followed.

@(private = "file")
runs :: proc(a: ^app.App, section, key: string) -> string {
    s, _ := app.section_find(a, section)
    path, _ := app.section_path(a, s)
    chord, _ := input.chord_parse(key, nil)
    b, _ := input.bind_lookup(a.binds[:], chord, path)
    return b.line
}

@(test)
a_header_list_orders_the_lookup :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, `[global]
f9 = :g
f8 = :g
f7 = :g
f6 = :g
f5 = :g
[fish]
f7 = :fish
[cat] (fish)
f8 = :cat
[dog]
f8 = :dog
f6 = :dog
[term] (cat dog)
f9 = :term
`, "binds.conf")
    testing.expect_value(t, len(a.gripes), 0)

    testing.expect_value(t, runs(&a, "term", "f9"), ":term") // own rows first
    testing.expect_value(t, runs(&a, "term", "f8"), ":cat") // then the list, in its order
    testing.expect_value(t, runs(&a, "term", "f6"), ":dog")
    testing.expect_value(t, runs(&a, "term", "f5"), ":g") // then global
    // cat lists fish, and term does not walk it: one level, never a chain.
    testing.expect_value(t, runs(&a, "term", "f7"), ":g")
    testing.expect_value(t, runs(&a, "cat", "f7"), ":fish")
}

@(test)
a_second_list_for_one_section_is_reported :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[fish]\nf7 = :fish\n[mine] (fish)\n[mine] (text)\n", "binds.conf")

    testing.expect(t, strings.contains(a.message, "binds.conf:4"), a.message)
    testing.expect_value(t, runs(&a, "mine", "f7"), ":fish") // the first list stands
}

// `send` hands what nothing claims to the document's own program, after global has had its say.
@(test)
send_forwards_only_what_nothing_claims :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    path, send := app.section_path(&a, app.SEC_TERM)
    testing.expect(t, send, "the terminal does not take what nothing claims")
    alt_e, _ := input.chord_parse("alt+@AD03", nil)
    b, global := input.bind_lookup(a.binds[:], alt_e, path)
    testing.expect(t, global && b.line == ":ring edit", "a global row stopped answering in a session")

    f9, _ := input.chord_parse("f9", nil)
    said := input.describe_chord(a.binds[:], f9, path, send, nil, app.names(&a),
                                 context.temp_allocator)
    testing.expect(t, strings.contains(said, "document's own job"), said)

    // The file decides: any section can send, and a list without it stops the default.
    app.binds_parse(&a, "[fish] (send)\n[term] (text)\n", "binds.conf")
    fish, _ := app.section_find(&a, "fish")
    _, send = app.section_path(&a, fish)
    testing.expect(t, send, "a group named in no kind cannot send")
    path, send = app.section_path(&a, app.SEC_TERM)
    testing.expect(t, !send, "a list without send still forwards")
    testing.expect_value(t, len(path), 3) // term, text, global
}

// A name used once that no kind answers to is a typo far more often than a group: a lone header
// and a lone list entry are both reported, a name used twice is not.
@(test)
a_name_used_once_is_reported :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[fiels]\nf7 = :x\n[term] (txt fish)\n[fish]\nf8 = :y\n", "binds.conf")

    said := make([dynamic]string, context.temp_allocator)
    for g in a.gripes {
        append(&said, g.why)
    }
    all := strings.join(said[:], "; ", context.temp_allocator)
    testing.expect_value(t, len(a.gripes), 2)
    testing.expect(t, strings.contains(all, "fiels is used once"), all)
    testing.expect(t, strings.contains(all, "txt is used once"), all)
}

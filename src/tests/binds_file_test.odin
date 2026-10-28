package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../input"
import "lues:lues"
import app "../oket"

// binds.conf (§8): the file lays over the kernel's defaults, a row can name a command LINE
// rather than a verb, and a requested row becomes text in the file instead of a claim on the
// table. Clashes are loud, which is the rule the whole facility exists for.

@(private = "file")
fixture :: proc() -> (a: app.App) {
    a, _ = app.app_make()
    a.binds = app.binds_base()
    return
}

@(private = "file")
close :: proc(a: ^app.App) {
    app.app_destroy(a)
}

@(private = "file")
find :: proc(a: ^app.App, spelling: string, s: app.Section) -> (input.Bind, bool) {
    chord, ok := input.chord_parse(spelling, nil)
    if !ok {
        return {}, false
    }
    path, _ := app.section_path(a, s)
    b, found := input.bind_lookup(a.binds[:], chord, path)
    return b, found
}

@(test)
binds_file_lays_over_the_defaults :: proc(t: ^testing.T) {
    a := fixture()
    defer close(&a)

    before, _ := find(&a, "f3", app.SEC_TEXT)
    testing.expect_value(t, before.line, ":search.next")

    app.binds_parse(&a, "[text]\nf3 = :file.dump\nclick = :open $o_path\n", "binds.conf")

    after, found := find(&a, "f3", app.SEC_TEXT)
    testing.expect(t, found)
    testing.expect_value(t, after.line, ":file.dump")
    testing.expect_value(t, after.origin.src, input.Origin_Src.Config)
    testing.expect_value(t, after.origin.line, 2)

    // A mouse row is an ordinary row: same file, same parser, same table.
    click, clicked := find(&a, "click", app.SEC_TEXT)
    testing.expect(t, clicked)
    testing.expect_value(t, click.line, ":open $o_path")
}

// A row naming nothing is reported and skipped. One typo does not cost the rest of the file.
@(test)
binds_file_skips_what_it_cannot_read :: proc(t: ^testing.T) {
    a := fixture()
    defer close(&a)

    app.binds_parse(
        &a,
        "[nowhere]\nf3 = :file.dump\n[text]\nnotachord = :file.dump\nf7 = :file.dump\n",
        "binds.conf",
    )
    still, _ := find(&a, "f3", app.SEC_TEXT)
    testing.expect_value(t, still.line, ":search.next")

    b, found := find(&a, "f7", app.SEC_TEXT)
    testing.expect(t, found, "a good row after two bad ones was dropped")
    testing.expect_value(t, b.line, ":file.dump")
    testing.expect(t, strings.contains(a.message, "binds.conf:4"))
}

// A value is a command line. A lone `:verb` is the verb itself; anything else runs as typed, so
// a bare name is a shell command.
@(test)
a_value_is_a_command_line :: proc(t: ^testing.T) {
    a := fixture()
    defer close(&a)
    for row in ([?]struct {
            value: string,
            want:  string,
        }{
            {":file.dump", ":file.dump"},
            {"none", ""},
            {":file.dump now", ":file.dump now"},
            {"file.dump", "file.dump"},
        }) {
        got := app.binds_line(row.value)
        defer delete(got)
        testing.expectf(t, got == row.want, "%q parsed as %q", row.value, got)
        testing.expect_value(t, app.binds_value(got), row.value)
    }
}

// A requested row becomes text in the file, and the file decides from then on. The header is
// the memory: delete a row and it stays deleted; delete the header and the defaults come back.
@(test)
a_requested_row_becomes_a_file_row :: proc(t: ^testing.T) {
    dir, ok := binds_scratch(t, "oket-binds-writeback")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    a := fixture()
    defer close(&a)
    app.app_home(&a, dir)

    lues.bind_request(a.kernel, "files", "surface", "click", ":open $o_path")
    app.binds_sync(&a)

    text := read(t, app.binds_path(&a))
    testing.expect(t, strings.contains(text, lues.owner_marker("files")))
    testing.expect(t, strings.contains(text, "[surface]"))
    testing.expect(t, strings.contains(text, "click = :open $o_path"))

    b, found := find(&a, "click", app.SEC_SURFACE)
    testing.expect(t, found)
    testing.expect_value(t, b.origin.src, input.Origin_Src.Config)

    // A second sync writes nothing more: the header says this owner has been through here.
    app.binds_sync(&a)
    testing.expect_value(t, read(t, app.binds_path(&a)), text)
}

// A chord already held on the same tier goes in COMMENTED, never dropped and never stolen: the
// row is there to uncomment once the other one has moved. Silent last-loaded-wins is the thing
// this rule exists to kill.
@(test)
a_taken_chord_is_written_commented_and_reported :: proc(t: ^testing.T) {
    dir, ok := binds_scratch(t, "oket-binds-clash")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    a := fixture()
    defer close(&a)
    app.app_home(&a, dir)

    // wheel-down is a kernel default at Global, so a Global request for it collides.
    lues.bind_request(a.kernel, "noisy", "global", "wheel-down", ":open $o_path")
    app.binds_sync(&a)

    text := read(t, app.binds_path(&a))
    testing.expect(t, strings.contains(text, "# wheel-down = :open $o_path"))
    testing.expect(t, strings.contains(text, "taken by :view.scroll_down"))

    testing.expect(t, strings.contains(a.message, "wheel-down is taken by :view.scroll_down"), a.message)

    // The default still answers, so the refusal cost nothing.
    b, _ := find(&a, "wheel-down", app.SEC_GLOBAL)
    testing.expect_value(t, b.line, ":view.scroll_down")
}

// A narrower row covering a wider one is the point of context scoping, so it goes in LIVE — with
// a note, because a shadow you cannot see is what §8 is about.
@(test)
a_shadowing_row_goes_in_live_with_a_note :: proc(t: ^testing.T) {
    dir, ok := binds_scratch(t, "oket-binds-shadow")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    a := fixture()
    defer close(&a)
    app.app_home(&a, dir)

    // f1 is describe.key at Global; a surface row covers it there and nowhere else.
    lues.bind_request(a.kernel, "files", "surface", "f1", ":help $o_path")
    app.binds_sync(&a)

    text := read(t, app.binds_path(&a))
    testing.expect(t, strings.contains(text, "# shadows :describe.key"))
    testing.expect(t, strings.contains(text, "f1 = :help $o_path"))


    b, _ := find(&a, "f1", app.SEC_SURFACE)
    testing.expect_value(t, b.line, ":help $o_path")

    wider, _ := find(&a, "f1", app.SEC_GLOBAL)
    testing.expect_value(t, wider.line, ":describe.key")
}

@(private = "file")
read :: proc(t: ^testing.T, path: string) -> string {
    raw, err := os.read_entire_file(path, context.temp_allocator)
    testing.expectf(t, err == nil, "cannot read %s: %v", path, err)
    return string(raw)
}

@(private = "file")
binds_scratch :: proc(t: ^testing.T, name: string) -> (dir: string, ok: bool) {
    tmp, _ := os.temp_directory(context.temp_allocator)
    dir, _ = filepath.join({tmp, name}, context.temp_allocator)
    os.remove_all(dir)
    if err := os.make_directory(dir); err != nil {
        testing.expectf(t, false, "cannot make %s: %v", dir, err)
        return "", false
    }
    return dir, true
}

// A primer is declared by its CHILDREN (CHORDS.md §4.1), so the chord space under one is shared:
// two plugins hang rows off `ctrl+b` and neither owns it. Both go in live — the clash rule is
// per chord PAIR, and `ctrl+b ctrl+a` is not `ctrl+b ctrl+f` — and one primer lists both.
@(test)
two_owners_share_one_primer :: proc(t: ^testing.T) {
    dir, ok := binds_scratch(t, "oket-binds-shared-primer")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    a := fixture()
    defer close(&a)
    app.app_home(&a, dir)

    lues.bind_request(a.kernel, "alpha", "global", "ctrl+@AB05 ctrl+@AC01", ":ls")
    lues.bind_request(a.kernel, "beta", "global", "ctrl+@AB05 ctrl+@AC04", ":ring")
    app.binds_sync(&a)

    text := read(t, app.binds_path(&a))
    testing.expect(t, strings.contains(text, "ctrl+@AB05 ctrl+@AC01 = :ls"), text)
    testing.expect(t, strings.contains(text, "ctrl+@AB05 ctrl+@AC04 = :ring"), text)
    testing.expect(t, !strings.contains(text, "taken by"), text) // neither took the other's chord

    prefix, parsed := input.chord_parse("ctrl+@AB05", nil)
    testing.expect(t, parsed)
    testing.expect(t, input.bind_primes(a.binds[:], prefix, sec_path(app.SEC_GLOBAL)), "no primer under ctrl+b")

    kids := input.bind_children(a.binds[:], prefix, sec_path(app.SEC_GLOBAL), nil, {}, context.temp_allocator)
    testing.expect(t, strings.contains(kids, ":ls"), kids)
    testing.expect(t, strings.contains(kids, ":ring"), kids)
}

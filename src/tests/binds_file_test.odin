package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../input"
import app "../oket"

// binds.conf (§8): the file lays over the kernel's defaults, a row can name a command LINE
// rather than a verb, and a requested row becomes text in the file instead of a claim on the
// table. Clashes are loud, which is the rule the whole facility exists for.

@(private = "file")
fixture :: proc() -> (a: app.App) {
    a.binds = input.binds_default()
    return
}

@(private = "file")
close :: proc(a: ^app.App) {
    input.binds_destroy(&a.binds)
    app.binds_requests_destroy(a)
    app.message_set(a, "")
    delete(a.home)
}

@(private = "file")
find :: proc(a: ^app.App, spelling: string, ctx: input.Bind_Ctx) -> (input.Bind, bool) {
    chord, ok := input.chord_parse(spelling, nil)
    if !ok {
        return {}, false
    }
    b, _, found := input.bind_lookup(a.binds[:], chord, ctx)
    return b, found
}

@(test)
binds_file_lays_over_the_defaults :: proc(t: ^testing.T) {
    a := fixture()
    defer close(&a)

    before, _ := find(&a, "f5", .Text)
    testing.expect_value(t, before.target, input.Bind_Target(input.Command.Reload))

    app.binds_parse(&a, "[text]\nf5 = edit.save\nclick = exec :open <path>\n", "binds.conf")

    after, found := find(&a, "f5", .Text)
    testing.expect(t, found)
    testing.expect_value(t, after.target, input.Bind_Target(input.Command.Save))
    testing.expect_value(t, after.origin.src, input.Origin_Src.Config)
    testing.expect_value(t, after.origin.line, 2)

    // A mouse row is an ordinary row: same file, same parser, same table.
    click, clicked := find(&a, "click", .Text)
    testing.expect(t, clicked)
    line, is_line := click.target.(input.Bind_Line)
    testing.expect(t, is_line)
    testing.expect_value(t, line.text, ":open <path>")
    testing.expect(t, !line.stage)
}

// A row naming nothing is reported and skipped. One typo does not cost the rest of the file.
@(test)
binds_file_skips_what_it_cannot_read :: proc(t: ^testing.T) {
    a := fixture()
    defer close(&a)

    app.binds_parse(
        &a,
        "[nowhere]\nf5 = edit.save\n[text]\nnotachord = edit.save\nf6 = not.a.verb\nf7 = edit.save\n",
        "binds.conf",
    )
    still, _ := find(&a, "f5", .Text)
    testing.expect_value(t, still.target, input.Bind_Target(input.Command.Reload))

    b, found := find(&a, "f7", .Text)
    testing.expect(t, found, "a good row after three bad ones was dropped")
    testing.expect_value(t, b.target, input.Bind_Target(input.Command.Save))
    testing.expect(t, strings.contains(a.message, "binds.conf:5"))
}

// `stage` puts the line in the command line for aiming rather than running it, which is the
// difference between Enter and Shift+Enter in one file (§5).
@(test)
binds_file_stages_as_well_as_runs :: proc(t: ^testing.T) {
    a := fixture()
    defer close(&a)
    app.binds_parse(&a, "[surface]\nclick = stage :open <path>\n", "binds.conf")

    b, _ := find(&a, "click", .Surface)
    line, is_line := b.target.(input.Bind_Line)
    testing.expect(t, is_line && line.stage)

    // A word, never a prefix: a verb whose name starts with one of the two is still a verb.
    _, made := app.binds_target("execute")
    testing.expect(t, !made)
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
    a.home = strings.clone(dir)

    app.binds_request(&a, "browser", "surface", "click", "exec :open <path>")
    app.binds_sync(&a)

    text := read(t, app.binds_path(&a))
    testing.expect(t, strings.contains(text, app.binds_header("browser")))
    testing.expect(t, strings.contains(text, "[surface]"))
    testing.expect(t, strings.contains(text, "click = exec :open <path>"))

    b, found := find(&a, "click", .Surface)
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
    a.home = strings.clone(dir)

    // wheel-down is a kernel default at Global, so a Global request for it collides.
    app.binds_request(&a, "noisy", "global", "wheel-down", "exec :open <path>")
    app.binds_sync(&a)

    text := read(t, app.binds_path(&a))
    testing.expect(t, strings.contains(text, "# wheel-down = exec :open <path>"))
    testing.expect(t, strings.contains(text, "taken by view.scroll_down"))

    testing.expect_value(t, len(a.clashes), 1)
    testing.expect_value(t, a.clashes[0].held, "view.scroll_down")
    testing.expect(t, !a.clashes[0].shadows)
    testing.expect(t, strings.contains(a.message, "already taken"))

    // The default still answers, so the refusal cost nothing.
    b, _ := find(&a, "wheel-down", .Global)
    testing.expect_value(t, b.target, input.Bind_Target(input.Command.View_Scroll_Down))
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
    a.home = strings.clone(dir)

    // f1 is describe.key at Global; a surface row covers it there and nowhere else.
    app.binds_request(&a, "browser", "surface", "f1", "exec :help <path>")
    app.binds_sync(&a)

    text := read(t, app.binds_path(&a))
    testing.expect(t, strings.contains(text, "# shadows describe.key"))
    testing.expect(t, strings.contains(text, "f1 = exec :help <path>"))

    testing.expect_value(t, len(a.clashes), 1)
    testing.expect(t, a.clashes[0].shadows)

    b, _ := find(&a, "f1", .Surface)
    _, is_line := b.target.(input.Bind_Line)
    testing.expect(t, is_line, "the narrow row did not win where it applies")

    wider, _ := find(&a, "f1", .Global)
    testing.expect_value(t, wider.target, input.Bind_Target(input.Command.Describe_Key))
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

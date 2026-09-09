package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import app "../oket"

// AUTHORING.md §6's gate: a sequence file drives a real kernel with a real plugin in it, all
// four line shapes act, and a failed assertion is counted and named rather than stopping the
// run.
//
// The subject is `harness_script`, which is the half of §6 that is not the entry point —
// `--harness` builds an App and this drives it, split apart for exactly this reason.

@(private = "file")
sequence :: proc(t: ^testing.T, dir, name, text: string) -> string {
    path, _ := filepath.join({dir, name}, context.temp_allocator)
    if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", path, err)
        return ""
    }
    return path
}

// One pass over all four shapes, over the editor, because a chain line, a chord and typed text
// only mean anything against a document that takes all three. The assertions are the claim: the
// query language answers what the steps did, and it answers it from the same `get_value` `:get`
// reads. All four operators, because three of them have one arm each and nothing else reaches
// them.
@(test)
a_sequence_file_drives_a_plugin_through_every_line_shape :: proc(t: ^testing.T) {
    a, path, ok := harness_app(t, "oket-harness-gate", "one\ntwo\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    seq := sequence(t, home_dir(a.home), "repro.oks", fmt.tprintf(
`# a comment, and the blank line under it, are not steps

:open %s
! kind == edit
! lines == 3
> end
XY
! text == oneXY\ntwo
! text ~ oneXY
! text !~ zzz
! kind != term
! message == 
`, path))
    if seq == "" {
        return
    }
    testing.expect_value(t, app.harness_script(&a, seq), 0)
}

// A failed assertion names its line and the run CARRIES ON: a repro whose second step is wrong
// still has to say what its fifth did, or the file is only ever as long as its first bug. Four
// ways to fail, and each is a step and not a stop.
//
// No plugin here: what is under test is the RUNNER, and a document with lines in it is all the
// three assertions ask about. Every `plug_app` is a compiler invocation, and the suite is
// threaded.
@(test)
a_failed_assertion_is_counted_and_the_run_carries_on :: proc(t: ^testing.T) {
    a, dir, ok := seeded_app(t, "oket-harness-miss", "one\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    seq := sequence(t, dir, "miss.oks",
`! lines == 99
! nosuchname == 1
! lines <> 1
> not+a+chord
! lines == 1
`)
    if seq == "" {
        return
    }
    testing.expect_value(t, app.harness_script(&a, seq), 4)
}

// The three §6 dumps, which are the half no assertion covers: the bytes, the descriptor, and
// the span store by publisher. Asked through `:get` so the harness and the verb cannot answer
// differently.
@(test)
the_query_language_answers_the_bytes_the_descriptor_and_the_spans :: proc(t: ^testing.T) {
    a, _, ok := seeded_app(t, "oket-harness-get", "alpha\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    text, _ := app.get_value(&a, "text")
    testing.expect_value(t, strings.trim_space(text), "alpha")
    d, _ := app.get_value(&a, "desc")
    testing.expect(t, strings.contains(d, "editable true"), d)
    testing.expect(t, strings.contains(d, "ctx Text"), d)
    // Empty and not a refusal: nobody has published a run over this document, and a name the
    // set does not hold is the only thing that answers false.
    spans, known := app.get_value(&a, "spans")
    testing.expect(t, known && spans == "", spans)
    _, unknown := app.get_value(&a, "nosuchname")
    testing.expect(t, !unknown, "an unknown name has to refuse, or `!` would wait out its clock")
}

// `:harness` with nothing named runs the file you are LOOKING AT, which is the rule a bare
// `:pluginify` already follows. Asked of the resolver rather than by spawning a second oket to
// read the answer back.
@(test)
a_bare_harness_resolves_the_focused_file_to_the_sequence :: proc(t: ^testing.T) {
    a, made := bare_app()
    if !testing.expect(t, made, "no App") {
        return
    }
    defer close_app(&a)
    _, refused := app.harness_line(&a, "")
    testing.expect(t, !refused, "an empty ring named a sequence out of nothing")

    dir, scratched := scratch(t, "oket-harness-line")
    if !scratched {
        return
    }
    path, _ := filepath.join({dir, "repro.oks"}, context.temp_allocator)
    if err := os.write_entire_file(path, transmute([]u8)string("! lines == 1\n")); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", path, err)
        return
    }
    app.ring_add(&a, scratch_doc(&a, path, "! lines == 1"))
    line, named := app.harness_line(&a, "")
    testing.expect(t, named, "the focused file did not become the sequence")
    testing.expect(t, strings.contains(line, "--harness"), line)
    testing.expect(t, strings.has_suffix(line, path), line)
    // A named sequence and the plugins after it, in order, each an argument the shell reads back
    // as one.
    line, named = app.harness_line(&a, fmt.tprintf("%s plugins/edit example", path))
    testing.expect(t, named, "a named sequence was refused")
    testing.expect(t, strings.has_suffix(line, fmt.tprintf("%s plugins/edit example", path)), line)
    // A flag goes AHEAD of the sequence, or `--harness`'s own reading would take it for one.
    line, named = app.harness_line(&a, fmt.tprintf("--dump %s edit", path))
    testing.expect(t, named, "a flag was taken for the sequence")
    testing.expect(t, strings.has_suffix(line, fmt.tprintf("--dump %s edit", path)), line)
    _, known := app.harness_line(&a, fmt.tprintf("--nope %s", path))
    testing.expect(t, !known, "a flag it does not know was passed through")
}

// A kernel with an editable document in it and a directory to write a sequence into. No plugin:
// the `edit` kind is only needed where a sequence OPENS a file, and `scratch_doc` is the
// stand-in the suite already keeps for everything else (support_test.odin).
@(private = "file")
seeded_app :: proc(t: ^testing.T, name, text: string) -> (a: app.App, dir: string, ok: bool) {
    dir = scratch(t, name) or_return
    a = bare_app() or_return
    app.home_set(&a.home, dir) // owned by the App, freed with it
    path, _ := filepath.join({dir, "note.txt"}, context.temp_allocator)
    app.ring_add(&a, scratch_doc(&a, path, text))
    app.surface_draw(&a)
    return a, dir, true
}

// The editor loaded and a file written, for the one test whose sequence OPENS one: the kernel
// reads no file into a document of its own, so `:open` needs whoever owns the `edit` kind (§8).
@(private = "file")
harness_app :: proc(t: ^testing.T, name, text: string) -> (a: app.App, path: string, ok: bool) {
    a = plug_app(t, name, "plugins/edit") or_return
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "edit")), a.message) {
        close_plug_app(&a)
        return {}, "", false
    }
    path, _ = filepath.join({home_dir(a.home), "note.txt"}, context.temp_allocator)
    if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", path, err)
        close_plug_app(&a)
        return {}, "", false
    }
    app.surface_draw(&a) // the body rectangle a viewport follows a caret in
    return a, path, true
}

package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../store"
import "../txt"
import app "../oket"

// The rest of the gate for build order stage 5: the command line, and `exec` / `stage` reaching
// it from a bind row. The line is a document like any other, so what is tested here is mostly
// that it needed no key code of its own.

@(private = "file")
type :: proc(a: ^app.App, text: string) {
    for r in text {
        app.text_input(a, r)
    }
}

// alt+c opens it empty and alt+; opens it with the sigil typed. Both are one keystroke, so the
// prefix disambiguates two live namespaces rather than taxing either (§11).
@(test)
two_chords_open_the_line_and_one_of_them_types_the_sigil :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    app.handle_chord(&a, chord("AB03", {.Alt})) // alt+c
    testing.expect(t, app.cl_active(&a))
    testing.expect_value(t, app.cl_line(&a), "")

    app.handle_chord(&a, chord("ESC"))
    testing.expect(t, !app.cl_active(&a), "escape closes the line rather than quitting oket")
    testing.expect(t, !a.quit)

    app.handle_chord(&a, chord("AC10", {.Alt})) // alt+;
    testing.expect_value(t, app.cl_line(&a), ":")
}

// alt+. is the lane switch for the kinds that have no letter: a `stage` row, so the line opens
// with the builtin typed and the NAME left to you. Nothing about it is special-cased — it is a
// default bind whose text happens to end in a space, and the caret lands past it.
@(test)
one_chord_stages_the_ring_for_a_lane_with_no_letter :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    app.handle_chord(&a, chord("AB09", {.Alt})) // alt+.
    testing.expect(t, app.cl_active(&a))
    testing.expect_value(t, app.cl_line(&a), ":ring")
    testing.expect_value(t, app.active(&a).view.point.head.col, len(":ring "))
    type(&a, "grammars")
    testing.expect_value(t, app.cl_line(&a), ":ring grammars")
}

// The line is a real editable document (§11): typing, the delete verbs and the motions serve it
// through the same bind table and the same text ops a document gets.
@(test)
the_line_is_a_document_like_any_other :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    app.cl_show(&a)
    type(&a, ":lsx")
    app.handle_chord(&a, chord("BKSP"))
    testing.expect_value(t, app.cl_line(&a), ":ls")

    // ctrl+a is edit.home, over the line, from the same row that serves a document.
    app.handle_chord(&a, chord("AC01", {.Ctrl}))
    testing.expect_value(t, app.active(&a).view.point.head.col, 0)
    type(&a, "x")
    testing.expect_value(t, app.cl_line(&a), "x:ls")

    // And the keys aim at the LINE while it is open, never at the document behind it.
    testing.expect(t, app.active(&a) != app.ring_focused(&a))
}

// Enter submits, and what was submitted comes back with an arrow.
@(test)
enter_submits_and_the_arrows_walk_history :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    app.cl_show(&a)
    type(&a, ":ring text")
    app.handle_chord(&a, chord("RTRN"))
    testing.expect(t, !app.cl_active(&a))
    testing.expect_value(t, len(a.cl.history), 1)

    app.cl_show(&a)
    app.handle_chord(&a, chord("UP"))
    testing.expect_value(t, app.cl_line(&a), ":ring text")
    app.handle_chord(&a, chord("DOWN"))
    testing.expect_value(t, app.cl_line(&a), "", )
}

// `exec` runs the line and `stage` puts it in the command line for aiming. Two rows over one
// value, which is what replaces two code paths in a plugin (§8).
@(test)
exec_runs_a_bind_line_and_stage_aims_it :: proc(t: ^testing.T) {
    // The browser, because a DIRECTORY is what `:open` hands to the `files` kind and there is no
    // listing of the kernel's own behind it any more. What is under test is the aiming; the
    // plugin is here so the line at the end of it opens something.
    a, ok := plug_app(t, "oket-cl-bind", "plugins/files")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "files")), a.message) {
        return
    }
    dir := home_dir(a.home)
    sub, _ := filepath.join({dir, "sub"}, context.temp_allocator)
    os.make_directory(sub)
    id, opened := app.files_open(&a, dir)
    if !testing.expect(t, opened, a.message) {
        return
    }
    app.ring_add(&a, id)
    app.surface_draw(&a)

    // The chord is spelled PHYSICALLY: a layout glyph needs the scancode base input_init sets,
    // and a test has no window to set it from.
    app.binds_parse(&a, "[files]\nenter = stage :open <path>\n", "binds.conf")
    // Row 3 after filter: 0 filter, 1 .., 2 plugins, 3 sub
    txt.doc_set_head(store.store_doc(&a.docs, id), {3, 0}, false)
    app.point_sync(&a)

    // stage: the expanded line is sitting in the command line, unrun and editable.
    app.handle_chord(&a, chord("RTRN"))
    testing.expect(t, app.cl_active(&a))
    testing.expect_value(t, app.cl_line(&a), fmt.tprintf(":open %s/sub", dir))

    // The staged line can be aimed before it commits — the routing target is an argument.
    type(&a, " 3")
    app.handle_chord(&a, chord("RTRN"))
    testing.expect(t, !app.cl_active(&a))
    testing.expect_value(t, app.ring_slot(&a), 3)
    title := app.doc_title(&a, app.ring_focused(&a).doc)
    testing.expect(t, strings.has_suffix(title, "sub"), title)
}

// A value only reaches the shell as ONE argument (§8). A filename is attacker-controlled input:
// anyone who can write a file into a directory you list can otherwise put `&&` in a bind line.
@(test)
a_hole_value_cannot_break_out_of_its_line :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-cl-quote")
    if !made {
        return
    }
    defer os.remove_all(dir)
    evil, _ := filepath.join({dir, "a && touch owned.txt"}, context.temp_allocator)
    if err := os.write_entire_file(evil, transmute([]u8)string("x")); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", evil, err)
        return
    }

    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, listing_doc(&a, dir))
    app.surface_draw(&a)
    app.point_place(&a, 2, 0) // the row whose name holds the operator

    line, filled := app.bind_expand(&a, "rm <path>")
    testing.expect(t, filled)
    testing.expect_value(t, line, fmt.tprintf("rm '%s'", evil))

    // And it stays one segment: the chain split reads a quote the way the shell does.
    app.cl_parse(&a, line)
    testing.expect_value(t, len(a.chain.steps), 1)

    // An ordinary path is still bare, so a staged line stays readable.
    app.point_place(&a, 2, 1)
    plain, _ := app.bind_expand(&a, ":open <path>")
    testing.expect_value(t, plain, fmt.tprintf(":open %s/alpha.txt", dir))
}

// §14's open question, answered: a hole the document cannot fill REPORTS. A fall-through to a
// key job that may not exist is a silent no-op, which is the thing §8 exists to prevent.
@(test)
a_hole_that_cannot_be_filled_says_so :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-cl-hole")
    if !ok {
        return
    }
    defer close_app(&a)

    app.binds_parse(&a, "[home]\n@AC03 = exec :open <nothing>\n", "binds.conf")
    app.handle_chord(&a, chord("AC03")) // the d position

    testing.expect(t, !app.cl_active(&a), "the line never ran")
    testing.expect_value(t, a.message, "nothing here has a nothing")
    _ = dir
}

// The other half of the rule: a line with no hole needs no point, so it runs on a panel
// standing on nothing rather than swallowing the chord (§8). alt+w on a fresh strip is this.
@(test)
a_line_without_a_hole_needs_no_document :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    line, filled := app.bind_expand(&a, ":width 100 50")
    testing.expect(t, filled, "the chord was swallowed")
    testing.expect_value(t, line, ":width 100 50")

    _, holed := app.bind_expand(&a, ":open <path>") // a hole still needs a document
    testing.expect(t, !holed)
}

// The table is the definition of the core set (MENU.md §3), so a row with a hole in it is a
// builtin the menubar would list with nothing under it — or a usage a complaint cannot quote.
// Enumerated arrays make Odin refuse that for a verb; a table of rows needs this instead.
@(test)
every_builtin_row_is_complete :: proc(t: ^testing.T) {
    for b in app.BUILTINS {
        testing.expect(t, b.name != "", "a builtin with no name")
        testing.expectf(t, b.menu != "", "%s is in no menu", b.name)
        testing.expectf(t, b.doc != "", "%s has no definition", b.name)
        testing.expectf(t, b.run != nil, "%s runs nothing", b.name)
        testing.expectf(t, b.usage == fmt.tprintf(":%s", b.name) ||
                           strings.has_prefix(b.usage, fmt.tprintf(":%s ", b.name)),
                        "%s: the usage does not start with the name (%s)", b.name, b.usage)
    }
}

// Two rows answering to one name is the drift the table exists to prevent: which of them the
// walk reaches would be the order they happen to be written in.
@(test)
no_two_builtins_share_a_spelling :: proc(t: ^testing.T) {
    for b, i in app.BUILTINS {
        for other, j in app.BUILTINS {
            if i == j {
                continue
            }
            testing.expectf(t, b.name != other.name, "%s is written twice", b.name)
            testing.expectf(t, b.name != other.also, "%s is a name and an alias", b.name)
            if b.also != "" {
                testing.expectf(t, b.also != other.also, "%s is an alias twice", b.also)
            }
        }
        found, is_builtin := app.builtin_named(b.name)
        testing.expectf(t, is_builtin && found.name == b.name, "%s does not answer to itself",
                        b.name)
        if b.also != "" {
            alias, aliased := app.builtin_named(b.also)
            testing.expectf(t, aliased && alias.name == b.name, "%s does not answer to %s",
                            b.name, b.also)
        }
    }
}

// The one name the table must NOT answer to. `:` promised a builtin, so an unknown one stops
// the chain and says so rather than falling through to the shell.
@(test)
a_name_no_row_holds_is_not_a_builtin :: proc(t: ^testing.T) {
    _, is_builtin := app.builtin_named("nope")
    testing.expect(t, !is_builtin)
    _, empty := app.builtin_named("")
    testing.expect(t, !empty, "an empty name reached a row")
}

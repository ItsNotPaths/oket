package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../store"
import "../txt"
import app "../oket"
import "../cl"
import "../input"

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
// with the builtin typed and the NAME left to you. Nothing about it is special-cased — a staged
// line ends in a space, and the caret lands past it.
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
    app.binds_parse(&a, "[files]\nenter = :stage :open $o_path\n", "binds.conf")
    // Row 3 after filter: 0 filter, 1 .., 2 plugins, 3 sub
    txt.doc_set_head(store.store_doc(a.docs, id), {3, 0}, false)
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
a_field_value_cannot_break_out_of_its_line :: proc(t: ^testing.T) {
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

    line, filled := app.vars_fill(&a, "rm $o_path")
    testing.expect(t, filled)
    testing.expect_value(t, line, fmt.tprintf("rm '%s'", evil))

    // And it stays one segment: the chain split reads a quote the way the shell does.
    app.cl_parse(&a, line)
    testing.expect_value(t, len(a.chain.steps), 1)

    // An ordinary path is still bare, so a staged line stays readable.
    app.point_place(&a, 2, 1)
    plain, _ := app.vars_fill(&a, ":open $o_path")
    testing.expect_value(t, plain, fmt.tprintf(":open %s/alpha.txt", dir))
}

// A value holding a quote still arrives as ONE argument, with its bytes as they were: the
// builtin's own reader takes the quoting back off.
@(test)
a_field_value_with_a_quote_arrives_whole :: proc(t: ^testing.T) {
    for v in ([?]string{"it's", `it's "$HOME" \ ` + "`x`", "a'b && c"}) {
        quoted := cl.sh_arg(v)
        raw, got := cl.first_arg(quoted)
        testing.expect_value(t, got, v)
        testing.expect_value(t, raw, quoted)
        testing.expect_value(t, cl.arg_whole(quoted), v)
    }
}

// §14's open question, answered: a field the document does not carry REPORTS. A fall-through to a
// key job that may not exist is a silent no-op, which is the thing §8 exists to prevent.
@(test)
a_missing_field_says_so :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-cl-missing")
    if !ok {
        return
    }
    defer close_app(&a)

    app.binds_parse(&a, "[home]\n@AC03 = :open $o_nothing\n", "binds.conf")
    app.handle_chord(&a, chord("AC03")) // the d position

    testing.expect(t, !app.cl_active(&a), "the line never ran")
    testing.expect_value(t, a.message, "nothing here has $o_nothing")
    _ = dir
}

// The other half of the rule: a line naming no `$o_` field needs no point, so it runs on a panel
// standing on nothing rather than swallowing the chord (§8). alt+w on a fresh strip is this.
@(test)
a_line_without_a_field_needs_no_document :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    line, filled := app.vars_fill(&a, ":width 100 50")
    testing.expect(t, filled, "the chord was swallowed")
    testing.expect_value(t, line, ":width 100 50")

    _, filled = app.vars_fill(&a, ":open $o_path") // a field still needs a document
    testing.expect(t, !filled)
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

// Every kernel verb is typeable under its own name, and no BUILTINS row hides one: the walk
// checks BUILTINS first, so a clash would make the verb unreachable from the line.
@(test)
every_verb_is_a_builtin :: proc(t: ^testing.T) {
    for info, cmd in app.COMMANDS {
        if cmd == .None || cmd == .Surface_Send {
            continue
        }
        b, found := app.builtin_named(info.name)
        testing.expectf(t, found && b.name == info.name, "%s is not typeable", info.name)
        testing.expectf(t, strings.has_prefix(b.usage, fmt.tprintf(":%s", info.name)),
                        "%s: the usage does not start with the name (%s)", info.name, b.usage)
    }
    for b in app.BUILTINS {
        _, clash := app.command_named(b.name)
        testing.expectf(t, !clash, "builtin %s hides a verb", b.name)
        if b.also != "" {
            _, clash = app.command_named(b.also)
            testing.expectf(t, !clash, "builtin %s hides a verb", b.also)
        }
    }
    _, sends := app.builtin_named("surface.send")
    testing.expect(t, !sends, "surface.send has no typed form")
}

// A typed verb does what its chord does, and an argument it cannot take refuses the line.
@(test)
a_typed_verb_runs :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.cl_exec(&a, ":file.quit now")
    testing.expect(t, !a.quit, "a verb that takes nothing ran with an argument")
    app.cl_exec(&a, ":ring.goto")
    testing.expect_value(t, a.message, ":ring.goto <N>")
    app.cl_exec(&a, ":q")
    testing.expect(t, a.quit, ":q did not quit")
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

// A `[cmdline]` row answers only while the line is open, and the line still takes every `[text]`
// row under it.
@(test)
cmdline_rows_answer_only_on_the_open_line :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))
    app.binds_parse(&a, "[cmdline]\nf5 = :stage :hit\n", "binds.conf")

    app.handle_chord(&a, chord("FK05"))
    testing.expect(t, !app.cl_active(&a), "a cmdline row fired in a text document")

    app.cl_show(&a)
    type(&a, "ab")
    app.handle_chord(&a, chord("LEFT"))
    type(&a, "x")
    testing.expect_value(t, app.cl_line(&a), "axb")

    app.handle_chord(&a, chord("FK05"))
    testing.expect_value(t, app.cl_line(&a), ":hit")
}

// `:stage` takes the rest of the line whole, so a staged chain keeps its operators.
@(test)
stage_takes_the_rest_of_the_line :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    app.cl_exec(&a, ":stage :hit && :put | sort")
    testing.expect(t, app.cl_active(&a))
    testing.expect_value(t, app.cl_line(&a), ":hit && :put | sort")
}

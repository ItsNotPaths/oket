package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
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
    app.ring_add(&a, app.text_open(&a, "note", "x"))

    app.handle_chord(&a, chord("AB03", {.Alt})) // alt+c
    testing.expect(t, app.cl_active(&a))
    testing.expect_value(t, app.cl_line(&a), "")

    app.handle_chord(&a, chord("ESC"))
    testing.expect(t, !app.cl_active(&a), "escape closes the line rather than quitting oket")
    testing.expect(t, !a.quit)

    app.handle_chord(&a, chord("AC10", {.Alt})) // alt+;
    testing.expect_value(t, app.cl_line(&a), ":")
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
    app.ring_add(&a, app.text_open(&a, "note", "x"))

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
    testing.expect(t, app.active(&a) != app.ring_focused(&a.ring))
}

// Enter submits, and what was submitted comes back with an arrow.
@(test)
enter_submits_and_the_arrows_walk_history :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, app.text_open(&a, "note", "x"))

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
    a, dir, ok := listing_app(t, "oket-cl-bind")
    if !ok {
        return
    }
    defer close_app(&a)

    // The chord is spelled PHYSICALLY: a layout glyph needs the scancode base input_init sets,
    // and a test has no window to set it from.
    app.binds_parse(&a, "[files]\nenter = stage :open <path>\n", "binds.conf")
    app.point_place(&a, 2, 1) // the beta.txt row

    // stage: the expanded line is sitting in the command line, unrun and editable.
    app.handle_chord(&a, chord("RTRN"))
    testing.expect(t, app.cl_active(&a))
    testing.expect_value(t, app.cl_line(&a), fmt.tprintf(":open %s/beta.txt", dir))

    // The staged line can be aimed before it commits — the routing target is an argument.
    type(&a, " 3")
    app.handle_chord(&a, chord("RTRN"))
    testing.expect(t, !app.cl_active(&a))
    testing.expect_value(t, a.ring.focused, 3)
    title := app.doc_title(&a, app.ring_focused(&a.ring).doc)
    testing.expect(t, strings.has_suffix(title, "beta.txt"), title)
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
    app.ring_add(&a, app.listing_open(&a, dir))
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

    app.binds_parse(&a, "[files]\n@AC03 = exec :open <nothing>\n", "binds.conf")
    app.handle_chord(&a, chord("AC03")) // the d position

    testing.expect(t, !app.cl_active(&a), "the line never ran")
    testing.expect_value(t, a.message, "nothing here has a nothing")
    _ = dir
}

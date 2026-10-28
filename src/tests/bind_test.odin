package tests

import "core:strings"
import "core:testing"
import "../input"
import app "../oket"

// The gate for build order step 2: describe answers for every chord, including unbound ones.

@(test)
describe_answers_every_chord :: proc(t: ^testing.T) {
    binds := app.binds_base()
    defer input.binds_destroy(&binds)

    for e in input.KEY_NAMES {
        for mods in ([?]input.Mods{{}, {.Ctrl}, {.Ctrl, .Alt, .Shift}}) {
            s := input.describe_chord(binds[:], {e.code, mods}, sec_path(app.SEC_GLOBAL), false, nil, app.names(nil))
            defer delete(s)
            testing.expectf(t, s != "", "no answer for @%s", e.name)
            _, bound := input.bind_lookup(binds[:], {e.code, mods}, sec_path(app.SEC_GLOBAL))
            testing.expect_value(t, strings.contains(s, "unbound"), !bound)
        }
    }

    // A code outside the name table still gets an answer, and its spelling parses back.
    s := input.describe_chord(binds[:], {999, {.Alt}}, sec_path(app.SEC_GLOBAL), false, nil, app.names(nil))
    defer delete(s)
    testing.expect_value(t, s, "alt+@999 is unbound")
}

// The sizing model is a ROW, so describe reads the widths out rather than naming a verb that
// hides them (PANELS.md §5). Rebind the row and this answer changes with it.
@(test)
describe_reads_the_width_row_out :: proc(t: ^testing.T) {
    binds := app.binds_base()
    defer input.binds_destroy(&binds)
    w, _ := input.key_code("AD02")

    s := input.describe_chord(binds[:], {w, {.Alt}}, sec_path(app.SEC_GLOBAL), false, nil, app.names(nil))
    defer delete(s)
    testing.expect(t, strings.contains(s, "runs :width 33 50 66 100"), s)
}

@(test)
describe_names_the_command :: proc(t: ^testing.T) {
    binds := app.binds_base()
    defer input.binds_destroy(&binds)
    esc, _ := input.key_code("ESC")

    s := input.describe_chord(binds[:], {esc, {}}, sec_path(app.SEC_GLOBAL), false, nil, app.names(nil))
    defer delete(s)
    testing.expect_value(t, s, "esc (@ESC) runs file.quit: close the window [global, kernel default]")

    // The same key with a modifier is a different chord, and says so.
    s2 := input.describe_chord(binds[:], {esc, {.Ctrl}}, sec_path(app.SEC_GLOBAL), false, nil, app.names(nil))
    defer delete(s2)
    testing.expect_value(t, s2, "ctrl+esc (ctrl+@ESC) is unbound")
}

// A shifted chord is its own row, never a retry of the bare one. These are the shifted chords
// the defaults keep: motions extend, and the few a held shift reaches by accident or by habit.
@(test)
shift_rows_are_written_out :: proc(t: ^testing.T) {
    binds := app.binds_base()
    defer input.binds_destroy(&binds)
    key :: proc(name: string, mods: input.Mods) -> input.Chord {
        code, _ := input.key_code(name)
        return {code, mods}
    }
    for row in ([?]struct {
            chord: input.Chord,
            sec:   app.Section,
            want:  string,
        }{
            {key("DOWN", {.Shift}), app.SEC_TEXT, ":nav.down extend"},
            {key("DOWN", {.Shift}), app.SEC_SURFACE, ":nav.down extend"},
            {key("LEFT", {.Ctrl, .Shift}), app.SEC_TEXT, ":edit.word_left extend"},
            {key("HOME", {.Shift}), app.SEC_TEXT, ":edit.home extend"},
            {key("END", {.Ctrl, .Shift}), app.SEC_TEXT, ":edit.doc_end extend"},
            {key("UP", {.Ctrl, .Shift}), app.SEC_TEXT, ":edit.para_up extend"},
            {key("AC01", {.Ctrl, .Shift}), app.SEC_TEXT, ":edit.home extend"},
            {key("BKSP", {.Shift}), app.SEC_TEXT, ":edit.delete_back"},
            {key("RTRN", {.Shift}), app.SEC_TEXT, ":edit.newline"},
            {key("AB04", {.Ctrl, .Shift}), app.SEC_TERM, ":term.paste"},
            {key("AB01", {.Ctrl, .Shift}), app.SEC_TEXT, ":edit.redo"},
        }) {
        b, ok := input.bind_lookup(binds[:], row.chord, sec_path(row.sec))
        testing.expectf(t, ok && b.line == row.want, "%v in %v is %v", row.chord, row.sec, b.line)
    }

    // No retry: a shifted chord nothing names is unbound, not its bare twin.
    _, ok := input.bind_lookup(binds[:], key("TAB", {.Shift}), sec_path(app.SEC_TEXT))
    testing.expect(t, !ok, "shift+tab fell back to tab")

    // A Text bind is invisible from Global context: nothing to type into, nothing to run.
    _, ok = input.bind_lookup(binds[:], key("DOWN", {}), sec_path(app.SEC_GLOBAL))
    testing.expect(t, !ok)
}

@(test)
every_command_has_a_doc :: proc(t: ^testing.T) {
    for info, cmd in app.COMMANDS {
        testing.expectf(t, info.name != "" && info.doc != "", "%v is undocumented", cmd)
    }
}

// A second spelling reaches the same verb as its name, in binds.conf and on the line alike.
@(test)
a_verb_answers_to_its_second_spelling :: proc(t: ^testing.T) {
    cmd, found := app.command_named("q")
    testing.expect(t, found && cmd == .Quit)
    cmd, found = app.command_named("np")
    testing.expect(t, found && cmd == .Panel_Open)
}

@(test)
pending_states_always_have_a_label :: proc(t: ^testing.T) {
    // nil pending has no label, every real variant must: the bar renders it, and a state
    // that is not shown cannot exist.
    testing.expect_value(t, input.pending_describe(nil), "")
    testing.expect(t, input.pending_describe(input.Pending_Describe{}) != "")

    p: input.Pending = input.Pending_Describe{}
    input.pending_set(&p)
    testing.expect(t, p == nil)
}

// Context-specific rows shadow Global ones: esc reaches the job in a terminal and quits
// everywhere else.
@(test)
terminal_esc_shadows_quit :: proc(t: ^testing.T) {
    binds := app.binds_base()
    defer input.binds_destroy(&binds)
    esc, _ := input.key_code("ESC")

    b, ok := input.bind_lookup(binds[:], {esc, {}}, sec_path(app.SEC_TERM))
    testing.expect(t, ok)
    testing.expect_value(t, b.line, ":surface.send")

    b, ok = input.bind_lookup(binds[:], {esc, {}}, sec_path(app.SEC_TEXT))
    testing.expect(t, ok)
    testing.expect_value(t, b.line, ":file.quit")
}

// The ctx column is the whole safety argument for putting cut and the kills on ctrl+x
// and ctrl+k/u: Terminal is not in {.Text, .Surface}, so bind_find misses and the miss rule
// forwards the chord to the job. Get this wrong and every shell in the ring loses ctrl+u.
//
// ctrl+c and ctrl+v are claimed, by the terminal's own verbs rather than by editing's.
@(test)
the_terminal_keeps_the_chords_editing_took :: proc(t: ^testing.T) {
    binds := app.binds_base()
    defer input.binds_destroy(&binds)

    ctrl :: proc(key: string) -> input.Chord {
        code, _ := input.key_code(key)
        return {code, {.Ctrl}}
    }

    for e in ([?]struct {
            key: string,
            cmd: app.Command,
        }{
            {"AB02", .Cut},
            {"AC08", .Kill_Line},
            {"AD07", .Kill_To_Line_Start},
        }) {
        b, bound := input.bind_lookup(binds[:], ctrl(e.key), sec_path(app.SEC_SURFACE))
        got, _ := app.line_command(b.line)
        testing.expectf(t, bound && got == e.cmd, "@%s does not reach %v", e.key, e.cmd)

        _, claimed := input.bind_lookup(binds[:], ctrl(e.key), sec_path(app.SEC_TERM))
        testing.expectf(t, !claimed, "@%s was taken from the terminal", e.key)
    }

    // ctrl+v pastes in a session too, and so does ctrl+shift+v, every terminal's paste.
    for mods in ([?]input.Mods{{.Ctrl}, {.Ctrl, .Shift}}) {
        v, _ := input.key_code("AB04")
        paste, _ := input.bind_lookup(binds[:], {v, mods}, sec_path(app.SEC_TERM))
        got, _ := app.line_command(paste.line)
        testing.expect_value(t, got, app.Command.Term_Paste)
    }

    // ctrl+c means copy in every document, the terminal included, so the chord resolves in both
    // contexts — to editing's verb in a surface and to the terminal's own in a session.
    surface, _ := input.bind_lookup(binds[:], ctrl("AB03"), sec_path(app.SEC_SURFACE))
    in_surface, _ := app.line_command(surface.line)
    testing.expect_value(t, in_surface, app.Command.Copy)

    session, _ := input.bind_lookup(binds[:], ctrl("AB03"), sec_path(app.SEC_TERM))
    in_term, _ := app.line_command(session.line)
    testing.expect_value(t, in_term, app.Command.Term_Copy)

    // So the interrupt is a row of its own, and a shell still has a way to say stop.
    c, _ := input.key_code("AB03")
    stop, _ := input.bind_lookup(binds[:], {c, {.Ctrl, .Shift}}, sec_path(app.SEC_TERM))
    interrupt, _ := app.line_command(stop.line)
    testing.expect_value(t, interrupt, app.Command.Surface_Send)

    // And narrowed to the terminal. A browser has no job to send to, so it must NOT reach
    // surface.send and report "this document has no job of its own".
    _, outside := input.bind_lookup(binds[:], {c, {.Ctrl, .Shift}}, sec_path(app.SEC_SURFACE))
    testing.expect(t, !outside, "ctrl+shift+c is bound outside the terminal")

    // ctrl+a and ctrl+e are {.Text}, so they answer in the command line and NOWHERE else: a
    // surface gets them through oket_doc's own table and a terminal through readline, both
    // by the miss rule. A kernel row at .Surface would take them from both.
    for key in ([?]string{"AC01", "AD03"}) {
        _, in_text := input.bind_lookup(binds[:], ctrl(key), sec_path(app.SEC_TEXT))
        testing.expectf(t, in_text, "@%s does not answer in the command line", key)
        for s in ([?]app.Section{app.SEC_SURFACE, app.SEC_TERM}) {
            _, claimed := input.bind_lookup(binds[:], ctrl(key), sec_path(s))
            testing.expectf(t, !claimed, "@%s was taken from %v", key, s)
        }
    }
    _, sends := app.section_path(nil, app.SEC_TERM)
    testing.expect(t, sends, "the terminal does not take what nothing claims")
}

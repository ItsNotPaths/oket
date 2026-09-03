package tests

import "core:strings"
import "core:testing"
import "../input"

// The gate for build order step 2: describe answers for every chord, including unbound ones.

@(test)
describe_answers_every_chord :: proc(t: ^testing.T) {
    binds := input.binds_default()
    defer input.binds_destroy(&binds)

    for e in input.KEY_NAMES {
        for mods in ([?]input.Mods{{}, {.Ctrl}, {.Ctrl, .Alt, .Shift}}) {
            s := input.describe_chord(binds[:], {e.code, mods, 0}, .Global, nil)
            defer delete(s)
            testing.expectf(t, s != "", "no answer for @%s", e.name)
            _, _, bound := input.bind_lookup(binds[:], {e.code, mods, 0}, .Global)
            testing.expect_value(t, strings.contains(s, "unbound"), !bound)
        }
    }

    // A code outside the name table still gets an answer, and its spelling parses back.
    s := input.describe_chord(binds[:], {999, {.Alt}, 0}, .Global, nil)
    defer delete(s)
    testing.expect_value(t, s, "alt+@999 is unbound")
}

@(test)
describe_names_the_command :: proc(t: ^testing.T) {
    binds := input.binds_default()
    defer input.binds_destroy(&binds)
    esc, _ := input.key_code("ESC")

    s := input.describe_chord(binds[:], {esc, {}, 0}, .Global, nil)
    defer delete(s)
    testing.expect_value(t, s, "esc (@ESC) runs quit: close the window [global, kernel default]")

    // The same key with a modifier is a different chord, and says so.
    s2 := input.describe_chord(binds[:], {esc, {.Ctrl}, 0}, .Global, nil)
    defer delete(s2)
    testing.expect_value(t, s2, "ctrl+esc (ctrl+@ESC) is unbound")
}

// Shift is not written into motion binds: it falls back to the bare chord and extends. An
// exact Shift row names a different verb and beats the fallback.
@(test)
shift_extends_or_names_its_own_verb :: proc(t: ^testing.T) {
    binds := input.binds_default()
    defer input.binds_destroy(&binds)
    down, _ := input.key_code("DOWN")
    z, _ := input.key_code("AB01")

    b, extend, ok := input.bind_lookup(binds[:], {down, {.Shift}, 0}, .Text)
    testing.expect(t, ok && extend)
    testing.expect_value(t, b.target, input.Bind_Target(input.Command.Nav_Down))

    b, extend, ok = input.bind_lookup(binds[:], {z, {.Ctrl, .Shift}, 0}, .Text)
    testing.expect(t, ok && !extend) // the exact row wins, no extending
    testing.expect_value(t, b.target, input.Bind_Target(input.Command.Redo))

    // A Text bind is invisible from Global context: nothing to type into, nothing to run.
    _, _, ok = input.bind_lookup(binds[:], {down, {}, 0}, .Global)
    testing.expect(t, !ok)
}

@(test)
every_command_has_a_doc :: proc(t: ^testing.T) {
    for info, cmd in input.COMMANDS {
        testing.expectf(t, info.name != "" && info.doc != "", "%v is undocumented", cmd)
    }
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
    binds := input.binds_default()
    defer input.binds_destroy(&binds)
    esc, _ := input.key_code("ESC")

    b, _, ok := input.bind_lookup(binds[:], {esc, {}, 0}, .Terminal)
    testing.expect(t, ok)
    testing.expect_value(t, b.target, input.Bind_Target(input.Command.Surface_Send))

    b, _, ok = input.bind_lookup(binds[:], {esc, {}, 0}, .Text)
    testing.expect(t, ok)
    testing.expect_value(t, b.target, input.Bind_Target(input.Command.Quit))
}

// The ctx column is the whole safety argument for putting cut, copy and paste on ctrl+x/c/v:
// Terminal is not in {.Text, .Surface}, so bind_find misses and the miss rule forwards the
// chord to the job. Get this wrong and every shell in the ring loses its interrupt.
@(test)
the_terminal_keeps_the_chords_editing_took :: proc(t: ^testing.T) {
    binds := input.binds_default()
    defer input.binds_destroy(&binds)

    ctrl :: proc(key: string) -> input.Chord {
        code, _ := input.key_code(key)
        return {code, {.Ctrl}, 0}
    }

    for e in ([?]struct {
            key: string,
            cmd: input.Command,
        }{
            {"AB02", .Cut},
            {"AB03", .Copy},
            {"AB04", .Paste},
            {"AC08", .Kill_Line},
            {"AD07", .Kill_To_Line_Start},
        }) {
        b, _, bound := input.bind_lookup(binds[:], ctrl(e.key), .Surface)
        got, _ := input.bind_command(b)
        testing.expectf(t, bound && got == e.cmd, "@%s does not reach %v", e.key, e.cmd)

        _, _, claimed := input.bind_lookup(binds[:], ctrl(e.key), .Terminal)
        testing.expectf(t, !claimed, "@%s was taken from the terminal", e.key)
    }

    // ctrl+a and ctrl+e are {.Text}, so they answer in the command line and NOWHERE else: a
    // surface gets them through oket_doc's own table and a terminal through readline, both
    // by the miss rule. A kernel row at .Surface would take them from both.
    for key in ([?]string{"AC01", "AD03"}) {
        _, _, in_text := input.bind_lookup(binds[:], ctrl(key), .Text)
        testing.expectf(t, in_text, "@%s does not answer in the command line", key)
        for ctx in ([?]input.Bind_Ctx{.Surface, .Terminal}) {
            _, _, claimed := input.bind_lookup(binds[:], ctrl(key), ctx)
            testing.expectf(t, !claimed, "@%s was taken from %v", key, ctx)
        }
    }
    testing.expect_value(t, input.ctx_miss(.Terminal), input.Command.Surface_Send)
}

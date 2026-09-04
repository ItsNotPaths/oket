package tests

import "core:strings"
import "core:testing"
import "../input"
import app "../oket"

// Primers (§4): a chord that qualifies the next one. Every sequence is modified-modified, so an
// unmodified key after a primer is never part of a sequence and falls through — structurally,
// not by timing. That transparency is the whole difference between this and Emacs.

@(private = "file")
armed :: proc(a: ^app.App) -> (input.Pending_Prefix, bool) {
    p, up := a.pending.(input.Pending_Prefix)
    return p, up
}

@(private = "file")
chord :: proc(spelling: string) -> input.Chord {
    c, _ := input.chord_parse(spelling, nil)
    return c
}

// The three outcomes, in one pass: a child runs, an unmodified key falls through, and a modified
// chord no child claims is absorbed and reported.
@(test)
a_primer_qualifies_exactly_one_chord :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC04 = quit\n", "binds.conf")

    // The primer is nobody's row, so pressing it arms rather than running.
    app.handle_chord(&a, chord("ctrl+@AB05"))
    p, up := armed(&a)
    testing.expect(t, up, "the primer did not arm")
    testing.expect_value(t, p.chord, chord("ctrl+@AB05"))
    testing.expect(t, !a.quit)

    // The child, which is reachable only from here.
    app.handle_chord(&a, chord("ctrl+@AC04"))
    testing.expect(t, a.pending == nil, "the primer stayed up")
    testing.expect(t, a.quit, "the child did not run")

    // A modified chord no child claims is ABSORBED, and says so: dispatching it as itself would
    // fire an unrelated verb because a sequence did not exist.
    a.quit = false
    app.handle_chord(&a, chord("ctrl+@AB05"))
    app.handle_chord(&a, chord("ctrl+@AD05"))
    testing.expect(t, a.pending == nil)
    testing.expect(t, strings.contains(a.message, "unbound"), a.message)
}

// §4.1's rule, and the reason it is structural: an unmodified key clears the primer and then
// does exactly what it always did. f1 still opens describe, so the fall-through really ran.
@(test)
an_unmodified_key_after_a_primer_falls_through :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC04 = quit\n", "binds.conf")

    app.handle_chord(&a, chord("ctrl+@AB05"))
    app.handle_chord(&a, chord("f1"))
    _, still := armed(&a)
    testing.expect(t, !still, "the primer swallowed an unmodified key")
    _, describing := a.pending.(input.Pending_Describe)
    testing.expect(t, describing, "f1 did not reach its own row")
}

// Escape is unmodified, so the rule above would fall it through to quit. It cancels instead.
@(test)
escape_cancels_a_primer_rather_than_quitting :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC04 = quit\n", "binds.conf")

    app.handle_chord(&a, chord("ctrl+@AB05"))
    app.handle_chord(&a, chord("esc"))
    testing.expect(t, a.pending == nil)
    testing.expect(t, !a.quit, "escape fell through to quit")
}

// The one other hole in the transparency, and the only one: the reserved key lists the children
// and keeps the primer up, because one bar row does not hold six of them.
@(test)
the_help_key_lists_the_children :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC04 = quit\n", "binds.conf")

    app.handle_chord(&a, chord("ctrl+@AB05"))
    testing.expect(t, !strings.contains(app.bar_text(&a), "quit"), app.bar_text(&a))

    help, _ := input.key_code(input.PREFIX_HELP)
    app.handle_chord(&a, {help, {}, 0})
    p, still := armed(&a)
    testing.expect(t, still, "the help key dropped the primer")
    testing.expect(t, p.listing)
    testing.expect(t, strings.contains(app.bar_text(&a), "quit"), app.bar_text(&a))

    // And the child still runs from there: listing is a label, not a mode.
    app.handle_chord(&a, chord("ctrl+@AC04"))
    testing.expect(t, a.quit)
}

// A child is reachable from its primer or not at all. `bind_scan` filters on the prefix, and
// nothing retries a miss with the prefix dropped — that would be a resolution tier.
@(test)
a_child_is_invisible_without_its_primer :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC04 = quit\n", "binds.conf")

    app.handle_chord(&a, chord("ctrl+@AC04"))
    testing.expect(t, !a.quit, "the child ran with no primer up")
    testing.expect(t, a.pending == nil)
}

// Modified-modified, or it is not a sequence. `ctrl+b f` is refused at the parse with the rule
// named, because a row that silently does nothing is what §8 exists to prevent.
@(test)
a_sequence_is_two_modified_chords :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    app.binds_parse(&a, "[global]\nctrl+@AB05 @AC04 = quit\n", "binds.conf")
    testing.expect(t, strings.contains(a.message, "modifier"), a.message)

    // A button already moves point before dispatch, so it can never qualify what follows.
    app.binds_parse(&a, "[global]\nclick ctrl+@AC04 = quit\n", "binds.conf")
    testing.expect(t, strings.contains(a.message, "modifier"), a.message)

    // And three is a mode with extra steps.
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC04 ctrl+@AC08 = quit\n", "binds.conf")
    testing.expect(t, strings.contains(a.message, "two chords"), a.message)
}

// A chord that is both a primer and a row of its own. Neither wins on merit, so the kernel picks
// no winner: the home page reports it and the file decides.
@(test)
a_chord_that_is_both_is_reported :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[global]\nctrl+@AB05 = quit\nctrl+@AB05 ctrl+@AC04 = file.dump\n", "binds.conf")

    hits := input.bind_collisions(a.binds[:], nil, {}, context.temp_allocator)
    testing.expect_value(t, len(hits), 1)
    testing.expect_value(t, hits[0].runs, "quit")
    testing.expect_value(t, hits[0].kids, 1)

    // No priority: the scan answers with whichever row it reaches, and here that is the plain
    // one, so the primer never arms. That is the collision, not a bug in it.
    app.handle_chord(&a, chord("ctrl+@AB05"))
    testing.expect(t, a.pending == nil)
}

// Describe would call a primer unbound, because a primer is a row's prefix and never a row.
@(test)
describe_reads_a_primer_out :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC04 = quit\n", "binds.conf")

    f1, _ := input.key_code("FK01")
    app.handle_chord(&a, {f1, {}, 0})
    app.handle_chord(&a, chord("ctrl+@AB05"))
    testing.expect(t, strings.contains(a.message, "arms a primer"), a.message)
    testing.expect(t, strings.contains(a.message, "quit"), a.message)
}

// A primer never arms over a capture: while the command line is open it owns the keys, and
// arming would close it and lose the typed line.
@(test)
a_primer_does_not_arm_over_the_command_line :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC04 = quit\n", "binds.conf")

    app.cl_show(&a)
    app.handle_chord(&a, chord("ctrl+@AB05"))
    _, up := armed(&a)
    testing.expect(t, !up, "the primer armed over the command line")
    testing.expect(t, app.cl_active(&a), "the primer closed the command line")
}

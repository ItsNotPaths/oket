package tests

import "core:strings"
import "core:testing"
import "core:time"
import "../store"
import "../txt"
import app "../oket"

// Half the gate for build order stage 5: `:` runs, `&&` chains, and a shell step is a real link
// in the chain. §14's first open question is whether `binds.conf` plus chains covers the
// script-tier gap, and `:sel | ... | :put` is the part of the answer a bind table alone cannot
// give — Emacs's shell-command-on-region, with no interpreter anywhere.

// Run a line to its end. The frame loop does this by pumping once a frame; a test has no frames,
// so it pumps until the chain is idle.
@(private = "file")
run_line :: proc(a: ^app.App, line: string) {
    app.cl_exec(a, line)
    for i := 0; app.chain_busy(a) && i < 5000; i += 1 {
        app.sh_pump(a)
        time.sleep(2 * time.Millisecond)
    }
}

@(private = "file")
doc_text :: proc(a: ^app.App, id: store.Id) -> string {
    doc := store.store_doc(&a.docs, id)
    return doc == nil ? "" : txt.doc_string(doc, context.temp_allocator)
}

// The split is the shell's own reading of an operator: never inside quotes, after a backslash,
// or inside a subshell, `...` or $(...). What is left over goes on verbatim.
@(test)
the_chain_splits_the_way_a_shell_would :: proc(t: ^testing.T) {
    segs :: proc(line: string) -> string {
        out := make([dynamic]string, context.temp_allocator)
        for s in app.cl_split_chain(line) {
            append(&out, strings.concatenate({s.piped ? "|" : "&", s.text}, context.temp_allocator))
        }
        return strings.join(out[:], " ", context.temp_allocator)
    }

    testing.expect_value(t, segs(":ls && date"), "&:ls  & date")
    testing.expect_value(t, segs(":sel | sort | :put"), "&:sel  | sort  | :put")

    // Quoted, escaped and nested operators belong to the shell, not to us.
    testing.expect_value(t, segs(`echo "a && b"`), `&echo "a && b"`)
    testing.expect_value(t, segs(`echo 'a | b'`), `&echo 'a | b'`)
    testing.expect_value(t, segs(`echo a\&\&b`), `&echo a\&\&b`)
    testing.expect_value(t, segs("echo $(a && b)"), "&echo $(a && b)")
    testing.expect_value(t, segs("echo `a | b`"), "&echo `a | b`")

    // `||` is the shell's or-else and `|&` its pipe-with-stderr. One `|` alone is ours.
    testing.expect_value(t, segs("false || echo x"), "&false || echo x")
    testing.expect_value(t, segs("a |& b"), "&a |& b")
}

// Two shell steps in a row are ONE command with its operator put back, so bash does its own
// piping and we never marshal bytes between two shells. That is the whole reason `|` costs
// nothing here.
@(test)
adjacent_shell_steps_stay_one_command :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_parse(&a, "ls | grep x | wc -l")
    testing.expect_value(t, len(a.chain.steps), 1)
    testing.expect_value(t, a.chain.steps[0].text, "ls | grep x | wc -l")
    testing.expect(t, a.chain.steps[0].shell)

    app.cl_parse(&a, "make && :ls")
    testing.expect_value(t, len(a.chain.steps), 2)
    testing.expect_value(t, a.chain.steps[0].text, "make")
    testing.expect_value(t, a.chain.steps[1].text, "ls")
    testing.expect(t, !a.chain.steps[1].shell)

    // A builtin between two shell steps breaks the coalescing, and the `|` marks who takes what.
    app.cl_parse(&a, ":sel | sort -u | tr a b | :put")
    testing.expect_value(t, len(a.chain.steps), 3)
    testing.expect_value(t, a.chain.steps[1].text, "sort -u | tr a b")
    testing.expect(t, a.chain.steps[1].piped)
    testing.expect(t, a.chain.steps[2].piped)
}

// The headline: a document's text out through a shell pipeline and back in at point, with the
// kernel handling only the two boundaries a shell cannot see.
@(test)
sel_pipes_a_selection_out_and_put_brings_it_back :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := app.text_open(&a.docs, "note", "hello\nworld")
    app.ring_add(&a, id)

    // Nothing selected, so `:sel` takes the line under point — and selects it, so what `:put`
    // replaces is what you were shown.
    run_line(&a, ":sel | tr a-z A-Z | :put")
    testing.expect_value(t, doc_text(&a, id), "HELLO\nworld")

    // A whole-document selection round trips too, and `sort`'s trailing newline arrives as one.
    doc := store.store_doc(&a.docs, id)
    txt.doc_set_text(doc, "b\na\nc")
    txt.doc_select_all(doc)
    run_line(&a, ":sel | sort | :put")
    testing.expect_value(t, doc_text(&a, id), "a\nb\nc\n")
}

// `:put` with nothing piped into it is a refusal, not an insert of whatever happened to be
// lying around: the `|` is what says text should cross.
@(test)
put_needs_something_piped_into_it :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := app.text_open(&a.docs, "note", "keep me")
    app.ring_add(&a, id)

    run_line(&a, "echo spam && :put")
    testing.expect_value(t, doc_text(&a, id), "keep me")
    testing.expect_value(t, a.message, ":put: nothing was piped into it")

    // And a listing does not take typing, so it refuses whatever the pipe carried.
    app.ring_add(&a, app.listing_open(&a.docs, "."))
    run_line(&a, "echo spam | :put")
    testing.expect_value(t, a.message, ":put: this document does not take typing")
}

// A shell step with nothing to pipe into goes to N#, which is the default sink and the reason
// `echo` alone is still useful. A non-zero exit surfaces it and stops the chain.
@(test)
a_shell_step_reports_to_the_system_session :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, app.text_open(&a.docs, "note", "x"))
    run_line(&a, "echo out && echo more")

    sys := app.sys_slot(&a).doc
    text := doc_text(&a, sys)
    testing.expect(t, strings.contains(text, "$ echo out && echo more"), text)
    testing.expect(t, strings.contains(text, "out\nmore"), text)
    testing.expect(t, a.ring.focused != app.SLOT_SYSTEM, "a run that worked surfaces nothing")

    // && short-circuits, and the failure is what brings N# forward. The second step is a
    // BUILTIN, so this is our chain stopping and not bash's own &&.
    run_line(&a, "exit 3 && :close")
    testing.expect_value(t, a.ring.focused, app.SLOT_SYSTEM)
    testing.expect(t, app.lane_first(&a.ring, 0) != 0, ":close never ran")
}

// The sigil promised a builtin, so an unknown one stops the chain and says so rather than
// quietly falling through to the shell.
@(test)
an_unknown_builtin_stops_the_chain :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := app.text_open(&a.docs, "note", "x")
    app.ring_add(&a, id)
    run_line(&a, ":nope && :close")

    testing.expect(t, strings.contains(a.message, "not a builtin"), a.message)
    testing.expect(t, app.ring_focused(&a.ring) != nil, "the chain stopped before :close")
}

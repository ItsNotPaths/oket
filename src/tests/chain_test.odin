package tests

import "core:fmt"
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
        app.term_pump(a) // N0 is a PTY: nothing reports until its bytes reach the parser
        app.sh_pump(a)
        store.store_drain(&a.docs)
        time.sleep(2 * time.Millisecond)
    }
    // A builtin-only line goes idle without a single pump, and what it printed into N0 is
    // still in the VT: one more pump lands it in the store for the assertions to read.
    app.term_pump(a)
    store.store_drain(&a.docs)
}

// The split is the shell's own reading of an operator: never inside quotes, after a backslash,
// or inside a subshell, `...` or $(...). What is left over goes on verbatim.
@(test)
the_chain_splits_the_way_a_shell_would :: proc(t: ^testing.T) {
    segs :: proc(line: string) -> string {
        marks := [app.CL_Op]string{.And = "&", .Pipe = "|", .Or = "!"}
        out := make([dynamic]string, context.temp_allocator)
        for s in app.cl_split_chain(line) {
            append(&out, strings.concatenate({marks[s.op], s.text}, context.temp_allocator))
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

    // A parameter expansion is one word and so is bash's ANSI-C quoting, so an operator inside
    // either belongs to the shell. The one after the closing brace is still ours.
    testing.expect_value(t, segs("echo ${x:-a|b}"), "&echo ${x:-a|b}")
    testing.expect_value(t, segs("echo ${x:-a|b} | :put"), "&echo ${x:-a|b}  | :put")
    testing.expect_value(t, segs(`echo $'a\'b|c'`), `&echo $'a\'b|c'`)

    // `||` is a step operator like `&&`; `|&` is the shell's pipe-with-stderr and stays whole.
    testing.expect_value(t, segs("false || echo x"), "&false  ! echo x")
    testing.expect_value(t, segs("a |& b"), "&a |& b")

    // A comment ends the line and is dropped: a step is injected with its exit report after it
    // on the same line, so a comment carried through would swallow the report.
    testing.expect_value(t, segs("echo hi # note && :ls"), "&echo hi ")
    testing.expect_value(t, segs("# all of it"), "&")
    // Only where a word starts, and never inside quotes.
    testing.expect_value(t, segs("echo a#b"), "&echo a#b")
    testing.expect_value(t, segs(`echo '# not a comment'`), `&echo '# not a comment'`)
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
    testing.expect_value(t, a.chain.steps[1].op, app.CL_Op.Pipe)
    testing.expect_value(t, a.chain.steps[2].op, app.CL_Op.Pipe)

    // `||` coalesces between shell steps like the others, so bash keeps its own or-else; at a
    // builtin boundary it is ours.
    app.cl_parse(&a, "make || echo failed")
    testing.expect_value(t, len(a.chain.steps), 1)
    testing.expect_value(t, a.chain.steps[0].text, "make || echo failed")
    app.cl_parse(&a, ":close || :np")
    testing.expect_value(t, len(a.chain.steps), 2)
    testing.expect_value(t, a.chain.steps[1].op, app.CL_Op.Or)
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

    id := scratch_doc(&a, "note", "hello\nworld")
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

    id := scratch_doc(&a, "note", "keep me")
    app.ring_add(&a, id)

    run_line(&a, "echo spam && :put")
    testing.expect_value(t, doc_text(&a, id), "keep me")
    testing.expect_value(t, a.message, ":put: nothing was piped into it")

    // And a listing does not take typing, so it refuses whatever the pipe carried.
    app.ring_add(&a, listing_doc(&a, "."))
    run_line(&a, "echo spam | :put")
    testing.expect_value(t, a.message, ":put: this document does not take typing")
}

// A shell step with nothing to pipe into goes to N0, which is the default sink and the reason
// `echo` alone is still useful. A non-zero exit surfaces it and stops the chain.
@(test)
a_shell_step_reports_to_the_system_session :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, scratch_doc(&a, "note", "x"))
    run_line(&a, "echo out && echo more")

    // N0 is a real session, so the transcript is the shell's: the line it was handed, echoed by
    // its own line editor, and the output under it.
    sys := app.sys_slot(&a).doc
    text := doc_text(&a, sys)
    testing.expect(t, strings.contains(text, "echo out && echo more"), text)
    testing.expect(t, strings.contains(text, "out\nmore"), text)
    testing.expect(t, app.ring_slot(&a) != app.SLOT_ZERO, "a run that worked surfaces nothing")

    // && short-circuits, and the failure is what brings N0 forward. The second step is a
    // BUILTIN, so this is our chain stopping and not bash's own &&. The subshell is the test's:
    // a bare `exit` at the top level ends the session's shell, which is a different failure.
    run_line(&a, "(exit 3) && :close")
    testing.expect_value(t, app.ring_slot(&a), app.SLOT_ZERO)
    testing.expect(t, app.lane_first(&a.ring, 0) != 0, ":close never ran")
}

// A failing step whose output the chain was reading does NOT throw you to N0: the answer was
// going into the document you are looking at, and a terminal is the wrong place to be told.
// The bar says it instead. An uncaptured failure still surfaces, which is the test above.
@(test)
a_failure_the_chain_was_reading_reports_rather_than_surfaces :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "keep me")
    app.ring_add(&a, id)
    run_line(&a, "false | :put")

    testing.expect(t, app.ring_slot(&a) != app.SLOT_ZERO, "a chain feeding :put must not jump to N0")
    testing.expect_value(t, a.message, "the shell step exited 1")
    testing.expect_value(t, doc_text(&a, id), "keep me") // && short-circuited, so :put never ran
}

// A bare `exit` ends the session's shell itself: a step is not wrapped in a subshell (`cd`
// must work at the top level), so the report never comes and the death is the answer. The
// chain stops, N0 surfaces its last screen, and the next step gets a fresh shell.
@(test)
a_step_that_kills_the_shell_stops_the_chain :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, scratch_doc(&a, "note", "x"))
    run_line(&a, "exit 0 && :close")
    testing.expect_value(t, a.message, "N0's shell exited mid-step")
    testing.expect_value(t, app.ring_slot(&a), app.SLOT_ZERO)
    testing.expect(t, !a.job.live, "the job never came back to rest")
    testing.expect(t, app.lane_first(&a.ring, 0) != 0, ":close ran past a dead shell")

    run_line(&a, "echo revived")
    testing.expect(t, strings.contains(doc_text(&a, app.sys_slot(&a).doc), "revived"),
                   "no fresh shell answered")
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

    id := scratch_doc(&a, "note", "x")
    app.ring_add(&a, id)
    run_line(&a, ":nope && :close")

    testing.expect(t, strings.contains(a.message, "not a builtin"), a.message)
    testing.expect(t, app.ring_focused(&a) != nil, "the chain stopped before :close")
}

// `||` runs its step on a failure and skips it on a success, and a skipped step carries the
// verdict forward — the shell's own flat reading, at step level. A failure an `||` answers is
// not surfaced: the arm that runs is the response.
@(test)
an_or_step_answers_a_failure_and_a_success_skips_it :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    run_line(&a, "(exit 3) || :width 50")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 2)
    testing.expect(t, app.ring_slot(&a) != app.SLOT_ZERO, "a rescued failure surfaced N0")

    run_line(&a, "echo ok || :width 25")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 2) // the arm was skipped

    // A failed BUILTIN is rescued the same way, and the arm may be a SHELL step.
    run_line(&a, ":nope || :width 100")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL)
    run_line(&a, ":nope || echo rescued")
    testing.expect(t, strings.contains(doc_text(&a, app.sys_slot(&a).doc), "rescued"),
                   "the shell arm never ran")

    // `||` opening the line answers a failure that never happened, so nothing runs.
    run_line(&a, "|| :width 25")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL)
}

// `:get` puts state on the feed, address first — and with the chain already branching on a
// step's exit, that is a conditional with no new syntax.
@(test)
get_feeds_state_a_shell_step_can_branch_on :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    run_line(&a, ":get panel | grep -q '^1$' && :width 50")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 2)

    run_line(&a, ":get panel | grep -q '^7$' && :width 100")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 2) // the grep said no

    // Unpiped, it prints into N0 like `:ls` and surfaces it.
    run_line(&a, ":get panels")
    testing.expect(t, strings.contains(doc_text(&a, app.sys_slot(&a).doc), "1 "), "no listing in N0")
    testing.expect_value(t, app.ring_slot(&a), app.SLOT_ZERO)
}

// `:set` is one config.conf row, typed, through the same door the file's rows come in — so a
// key the file would refuse is refused here too, with the same kind of report.
@(test)
set_changes_a_setting_for_the_session :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    run_line(&a, ":set strip.gap 9")
    testing.expect_value(t, a.config.gap, 9)

    run_line(&a, ":set nope.x 1")
    testing.expect(t, strings.contains(a.message, "not a setting"), a.message)

    // An ordered-list key routes to the order table, not a Config field.
    run_line(&a, ":set menu.bar edit, view")
    names := app.config_names(&a.config, "menu", "bar")
    testing.expect_value(t, len(names), 2)
    testing.expect_value(t, names[0], "edit")
}

// `:do` is the loop: the shell generates command lines, and each runs as its own chain after
// this one ends. A line that fails does not take the queue with it — per-item failure is the
// item's, like xargs — and the transcript of what ran lands in N0.
@(test)
do_runs_the_piped_lines_after_the_chain :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))

    run_line(&a, `printf ':width 50\n:width 30\n' | :do`)
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 3)
    testing.expect(t, strings.contains(doc_text(&a, app.sys_slot(&a).doc), "> :width 50"),
                   "no transcript in N0")

    run_line(&a, `printf ':nope\n:width 100\n' | :do`)
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL) // the queue outlived :nope

    // A queued line may pipe into `:do` itself: the queue is the App's, so its parse eats
    // nothing behind it.
    run_line(&a, `printf 'printf ":width 25\\n" | :do\n' | :do`)
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 4)

    // The cap, at its edge: QUEUE_MAX lines go in, one more refuses the batch whole.
    run_line(&a, fmt.tprintf("seq %d | sed 's/.*/:width 50/' | :do", app.QUEUE_MAX))
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 2)
    run_line(&a, fmt.tprintf("seq %d | sed 's/.*/:width 100/' | :do", app.QUEUE_MAX + 1))
    testing.expect(t, strings.contains(a.message, "cap"), a.message)
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 2)
}

// `@*` acts on every panel; `#*` empties the lane; and an OPEN refuses both, because an open
// needs one place.
@(test)
a_star_names_every_panel_or_every_slot :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    one := scratch_doc(&a, "one", "x")
    app.ring_add(&a, one)
    app.ring_add(&a, scratch_doc(&a, "two", "y"))
    app.panel_make(&a, 1)

    run_line(&a, ":width 50 @*")
    for p in a.panels {
        testing.expect_value(t, p.size, app.WIDTH_FULL / 2)
    }

    run_line(&a, ":open nowhere #*")
    testing.expect(t, strings.contains(a.message, "one place"), a.message)

    // `:close #1` closes a slot you are not standing on; `#*` takes the rest of the lane.
    lane := app.ring_lane(&a)
    run_line(&a, ":close #1")
    testing.expect(t, app.lane_get(&a.ring, lane, 1) == nil, "slot 1 survived :close #1")
    testing.expect_value(t, app.ring_slot(&a), 2)
    run_line(&a, ":close #*")
    testing.expect_value(t, app.lane_first(&a.ring, lane), 0)
}

// An alias is a NAMED LINE, expanded at parse so the chain that runs is one you could have
// typed: it sequences with `&&`, keeps the operator it was called with, refuses arguments and
// cycles, and a builtin's name stays the builtin's.
@(test)
an_alias_is_a_named_line_that_composes :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    id := scratch_doc(&a, "note", "hello")
    app.ring_add(&a, id)

    testing.expect(t, app.config_set_line(&a.config, "alias", "half", ":width 50"),
                   "the alias row was refused")
    run_line(&a, ":half")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 2)
    run_line(&a, ":width 100 && :half")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 2) // ran second, after the &&

    // The body's first step takes the operator the NAME was called with, so a pipe into an
    // alias is a pipe into its body.
    app.config_set_line(&a.config, "alias", "up", "tr a-z A-Z | :put")
    run_line(&a, ":sel | :up")
    testing.expect_value(t, doc_text(&a, id), "HELLO")

    // The body expands FLAT, not as a subshell: a failure inside it is the chain's own
    // verdict, so the CALLER's `||` answers it.
    app.config_set_line(&a.config, "alias", "risky", ":nope && :width 30")
    run_line(&a, ":risky || :width 25")
    testing.expect_value(t, a.panels[0].size, app.WIDTH_FULL / 4)

    run_line(&a, ":half 3")
    testing.expect(t, strings.contains(a.message, "takes no arguments"), a.message)
    app.config_set_line(&a.config, "alias", "loop", ":loop")
    run_line(&a, ":loop")
    testing.expect(t, strings.contains(a.message, "too deep"), a.message)
    testing.expect(t, !app.config_set_line(&a.config, "alias", "close", ":q"),
                   "an alias took a builtin's name")

    // A plugin's registered name wins the clash SILENTLY: the alias never expands, and the
    // step goes to the plugin unchanged.
    append(&a.cmds, app.Plug_Cmd{name = "fake.cmd", owner = 0})
    app.config_set_line(&a.config, "alias", "fake.cmd", ":width 25")
    app.cl_parse(&a, ":fake.cmd")
    testing.expect_value(t, len(a.chain.steps), 1)
    testing.expect_value(t, a.chain.steps[0].text, "fake.cmd")
    delete(a.cmds) // the fake row's strings are literals; close_app never walks a.cmds
}

// The shipped vocabulary: `:panel.equalize` walks the strip through `:get`, awk and `:do`,
// and a file row with the same name replaces the shipped line.
@(test)
the_default_equalize_gives_every_panel_an_equal_share :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "note", "x"))
    app.panel_make(&a, 1)
    app.panel_make(&a, 2)

    run_line(&a, ":panel.equalize")
    for p in a.panels {
        testing.expect_value(t, p.size, app.WIDTH_FULL / 3)
    }

    app.config_set_line(&a.config, "alias", "panel.equalize", ":width 100")
    run_line(&a, ":panel.equalize")
    testing.expect_value(t, a.panels[a.focus].size, app.WIDTH_FULL)

    // A queued line goes through the same parse, so `:do` lines expand aliases too.
    app.config_set_line(&a.config, "alias", "panel.equalize", ":width 50")
    run_line(&a, `printf ':panel.equalize\n' | :do`)
    testing.expect_value(t, a.panels[a.focus].size, app.WIDTH_FULL / 2)

    // The override is this session's: a re-read of the file brings the shipped line back.
    app.config_load(&a)
    testing.expect_value(t, app.config_alias_line(&a.config, "panel.equalize"),
                         app.ALIASES_DEFAULT[0].line)
}

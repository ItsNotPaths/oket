package tests

import "core:strings"
import "core:testing"
import "core:time"
import "../store"
import "../txt"
import app "../oket"

// `[cmdline] live`: step 1 of the open line re-runs once typing pauses, when its verb is on the
// list. A preview never outlives the line: esc puts the carets back, enter runs the line for real.

@(private = "file")
live_app :: proc(text: string) -> (a: app.App, doc: ^txt.Doc, ok: bool) {
    a = bare_app(60, 10) or_return
    id := scratch_doc(&a, "note.txt", text)
    app.ring_add(&a, id)
    return a, store.store_doc(a.docs, id), true
}

// What the line says once typing has paused.
@(private = "file")
live_type :: proc(a: ^app.App, text: string) {
    for r in text {
        app.text_input(a, r)
    }
    app.cl_live_pump(a)
    time.sleep(app.LIVE_DEBOUNCE)
    app.cl_live_pump(a)
}

@(test)
a_live_find_selects_as_you_type :: proc(t: ^testing.T) {
    a, doc, ok := live_app("foo\nbar\nfoo")
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_show(&a)
    live_type(&a, ":find foo")
    testing.expect_value(t, len(doc.cursors), 2)
}

// Nothing runs before the pause, so a half-typed pattern is not searched for.
@(test)
a_live_find_waits_for_the_pause :: proc(t: ^testing.T) {
    a, doc, ok := live_app("foo\nbar\nfoo")
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_show(&a, ":find foo")
    app.cl_live_pump(&a)
    testing.expect_value(t, len(doc.cursors), 1)
}

// Only step 1 runs: what follows it waits for enter.
@(test)
a_live_line_runs_step_one_only :: proc(t: ^testing.T) {
    a, doc, ok := live_app("foo\nbar\nfoo")
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_show(&a)
    live_type(&a, ":find foo && :find bar")
    testing.expect_value(t, len(doc.cursors), 2)
}

// A verb off the list never runs live, and an empty list runs nothing.
@(test)
only_listed_verbs_run_live :: proc(t: ^testing.T) {
    a, doc, ok := live_app("foo\nbar\nfoo")
    if !ok {
        return
    }
    defer close_app(&a)

    for list in ([]string{"grep", ""}) {
        app.config_set_line(&a.config, app.LIVE_SECTION, "live", list)
        app.cl_show(&a)
        live_type(&a, ":find foo")
        testing.expect_value(t, len(doc.cursors), 1)
        app.cl_hide(&a)
    }
}

// Every run starts where point was when the line opened, so the landing hit does not walk as
// the pattern grows, and a pattern typed away leaves nothing selected.
@(test)
each_live_run_starts_from_the_open_point :: proc(t: ^testing.T) {
    a, doc, ok := live_app("ab\n.\nab\n.\nab")
    if !ok {
        return
    }
    defer close_app(&a)
    txt.doc_set_head(doc, {1, 0}, false)
    app.point_sync(&a)

    app.cl_show(&a)
    live_type(&a, ":find a")
    testing.expect_value(t, doc.cursors[doc.primary].head.line, 2)
    live_type(&a, "b")
    testing.expect_value(t, doc.cursors[doc.primary].head.line, 2)

    app.cl_show(&a, ":fin")
    live_type(&a, "")
    testing.expect_value(t, len(doc.cursors), 1)
    testing.expect_value(t, doc.cursors[0].head, txt.Pos{1, 0})
}

// esc leaves no carets behind, or typing next would replace every match.
@(test)
esc_puts_the_carets_back :: proc(t: ^testing.T) {
    a, doc, ok := live_app("foo\nbar\nfoo")
    if !ok {
        return
    }
    defer close_app(&a)
    txt.doc_set_head(doc, {1, 1}, false)
    app.point_sync(&a)

    app.cl_show(&a)
    live_type(&a, ":find foo")
    app.handle_chord(&a, chord("ESC"))
    testing.expect_value(t, len(doc.cursors), 1)
    testing.expect_value(t, doc.cursors[0].head, txt.Pos{1, 1})
}

@(test)
enter_runs_the_whole_line :: proc(t: ^testing.T) {
    a, doc, ok := live_app("foo\nbar\nfoo")
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_show(&a)
    live_type(&a, ":find foo && :find bar")
    app.handle_chord(&a, chord("RTRN"))
    testing.expect_value(t, len(doc.cursors), 1)
    testing.expect_value(t, doc.cursors[0].head, txt.Pos{1, 3})
}

// A pattern that is everywhere selects FIND_CAP hits from point on, not all of them.
@(test)
find_caps_its_selections :: proc(t: ^testing.T) {
    a, doc, ok := live_app(strings.repeat("x\n", app.FIND_CAP + 10, context.temp_allocator))
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_exec(&a, ":find x")
    testing.expect_value(t, len(doc.cursors), app.FIND_CAP)
    testing.expect(t, strings.contains(a.message, "from point"), a.message)
}

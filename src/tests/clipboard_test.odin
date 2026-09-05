package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "../store"
import "../txt"
import app "../oket"

// The system clipboard is the copy path in both directions (PLAN.md §8): what is copied here
// pastes into a browser, and a browser's copy pastes here. These gate the GLFW half of txt's
// doc_copy/doc_cut/doc_paste and nothing else.
//
// A test has no window, so GLFW answers nothing and the ring head is what clip_get falls back
// to. That fallback is the shipped path on X11 with the selection dropped, not a test hook.

@(test)
copy_then_paste_round_trips :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "hello\nworld")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    txt.doc_set_head(doc, {0, 0}, false)
    txt.doc_set_head(doc, {0, 5}, true)
    app.handle_chord(&a, chord("AB03", {.Ctrl})) // ctrl+c
    testing.expect_value(t, app.clip_head(&a).text, "hello")
    testing.expect_value(t, a.message, "copied")

    txt.doc_set_head(doc, {1, 5}, false)
    app.handle_chord(&a, chord("AB04", {.Ctrl})) // ctrl+v
    testing.expect_value(t, doc_text(&a, id), "hello\nworldhello")
}

// Cut is copy then delete, so a cut range reaches the clipboard by the path a copied one does.
@(test)
cut_leaves_the_text_on_the_clipboard :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "hello world")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    txt.doc_set_head(doc, {0, 6}, false)
    txt.doc_set_head(doc, {0, 11}, true)
    app.handle_chord(&a, chord("AB02", {.Ctrl})) // ctrl+x
    testing.expect_value(t, doc_text(&a, id), "hello ")
    testing.expect_value(t, app.clip_head(&a).text, "world")
}

// The verb reads "the selection, OR the line": a bare caret copies the line it stands on, with
// its newline, so it pastes back as a line rather than joining the one it lands in.
@(test)
copy_with_no_selection_takes_the_line :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo")
    app.ring_add(&a, id)
    txt.doc_set_head(store.store_doc(&a.docs, id), {0, 1}, false)

    app.handle_chord(&a, chord("AB03", {.Ctrl}))
    testing.expect_value(t, app.clip_head(&a).text, "one\n")
}

// Paste reads the CLIPBOARD, not a private buffer oket filled: text that arrived from outside
// is what lands. Setting the fallback is how a windowless test says "somebody else copied".
@(test)
paste_inserts_what_the_clipboard_holds :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "")
    app.ring_add(&a, id)
    app.clip_set(&a, "from a browser")

    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "from a browser")
}

// Copying is not editing, so it reaches a listing the same way select.all already does. Pasting
// IS editing, and the listing refuses it with the one message every write refusal gives.
@(test)
copy_reaches_a_listing_and_paste_does_not :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-clip-listing")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    app.handle_chord(&a, chord("AB03", {.Ctrl}))
    testing.expect_value(t, a.message, "copied")
    testing.expect(t, app.clip_head(&a).text != "", "a listing row should reach the clipboard")

    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    testing.expect_value(t, a.message, "this document does not take typing")
}

// A set with one selection and one bare caret copies only the selection, so the cut must skip
// the bare one too. Cutting its whole line would delete text the clipboard never saw.
@(test)
a_mixed_set_cuts_only_what_it_copied :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    txt.doc_set_head(doc, {0, 0}, false)
    txt.doc_set_head(doc, {0, 3}, true)
    txt.doc_add_cursor(doc, {1, 1}) // bare, on the line below

    app.handle_chord(&a, chord("AB02", {.Ctrl}))
    testing.expect_value(t, app.clip_head(&a).text, "one")
    testing.expect_value(t, doc_text(&a, id), "\ntwo")
}

// --- the kill verbs ---
//
// These gate the three spans and the empty-kill guard.

@(test)
kill_line_takes_the_rest_of_the_line :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "hello world\nnext")
    app.ring_add(&a, id)
    txt.doc_set_head(store.store_doc(&a.docs, id), {0, 5}, false)

    app.handle_chord(&a, chord("AC08", {.Ctrl})) // ctrl+k
    testing.expect_value(t, doc_text(&a, id), "hello\nnext")
    testing.expect_value(t, app.clip_head(&a).text, " world")
}

// At the end of a line the span takes the break instead, so a second ctrl+k joins the line below
// rather than stopping on an empty selection.
@(test)
kill_line_at_the_end_joins_the_next :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo")
    app.ring_add(&a, id)
    txt.doc_set_head(store.store_doc(&a.docs, id), {0, 3}, false)

    app.handle_chord(&a, chord("AC08", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "onetwo")
    testing.expect_value(t, app.clip_head(&a).text, "\n")
}

@(test)
kill_whole_line_and_kill_to_line_start :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo\nthree")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    txt.doc_set_head(doc, {1, 1}, false)
    app.handle_chord(&a, chord("AC08", {.Ctrl, .Shift})) // ctrl+shift+k
    testing.expect_value(t, doc_text(&a, id), "one\nthree")
    testing.expect_value(t, app.clip_head(&a).text, "two\n")

    txt.doc_set_head(doc, {1, 3}, false)
    app.handle_chord(&a, chord("AD07", {.Ctrl})) // ctrl+u
    testing.expect_value(t, doc_text(&a, id), "one\nee")
    testing.expect_value(t, app.clip_head(&a).text, "thr")

    // The LAST line has no break to take, so the whole-line span stops at its end.
    app.handle_chord(&a, chord("AC08", {.Ctrl, .Shift}))
    testing.expect_value(t, doc_text(&a, id), "one\n")
    testing.expect_value(t, app.clip_head(&a).text, "ee")
}

// A kill that selects nothing must do nothing: doc_cut reads an empty set as "take the line",
// and a skipped kill must not clobber the clipboard either.
@(test)
a_kill_of_nothing_leaves_the_line_alone :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)
    app.clip_set(&a, "kept")

    txt.doc_set_head(doc, {1, 0}, false)
    app.handle_chord(&a, chord("AD07", {.Ctrl})) // ctrl+u at column 0
    testing.expect_value(t, doc_text(&a, id), "one\ntwo")

    // And ctrl+k at the end of the LAST line, where there is no break left to take.
    txt.doc_set_head(doc, {1, 3}, false)
    app.handle_chord(&a, chord("AC08", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "one\ntwo")
    testing.expect_value(t, app.clip_head(&a).text, "kept")
}

// --- one piece per caret ---
//
// The clipboard carries only the joined text, so the split copy is kept beside it and the caret
// count is what decides whether it can be handed out.

@(test)
a_multi_caret_copy_pastes_one_piece_per_caret :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 8)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo\n.\n.")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    txt.doc_set_spans(doc, [][2]txt.Pos{{{0, 0}, {0, 3}}, {{1, 0}, {1, 3}}})
    app.handle_chord(&a, chord("AB03", {.Ctrl}))
    testing.expect_value(t, app.clip_head(&a).text, "one\ntwo") // the clipboard still gets one string

    txt.doc_set_spans(doc, [][2]txt.Pos{{{2, 1}, {2, 1}}, {{3, 1}, {3, 1}}})
    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "one\ntwo\n.one\n.two")
}

// The pieces are only good for the caret count that made them. Fewer carets take the joined
// string, which is what another program would have received.
@(test)
pieces_that_do_not_fit_the_carets_paste_whole :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 8)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo\n.")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    txt.doc_set_spans(doc, [][2]txt.Pos{{{0, 0}, {0, 3}}, {{1, 0}, {1, 3}}})
    app.handle_chord(&a, chord("AB03", {.Ctrl}))

    txt.doc_reset_cursor(doc, {2, 1})
    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "one\ntwo\n.one\ntwo")
}

// A copy from outside oket has no pieces, so every caret takes the whole of it.
@(test)
a_foreign_copy_lands_whole_at_every_caret :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 8)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", ".\n.")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    app.clip_set(&a, "X")
    txt.doc_set_spans(doc, [][2]txt.Pos{{{0, 1}, {0, 1}}, {{1, 1}, {1, 1}}})
    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), ".X\n.X")
}

// With nothing selected each caret copies its own line, so the pieces are lines and they go
// back one per caret the same way.
@(test)
bare_carets_copy_a_line_each :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 8)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    txt.doc_set_spans(doc, [][2]txt.Pos{{{0, 0}, {0, 0}}, {{1, 0}, {1, 0}}})
    app.handle_chord(&a, chord("AB03", {.Ctrl}))
    testing.expect_value(t, app.clip_head(&a).text, "one\ntwo\n")

    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "one\none\ntwo\ntwo")
}

// Cut feeds the clipboard by the copy path, so its pieces paste one per caret the same way.
@(test)
a_multi_caret_cut_pastes_one_piece_per_caret :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 8)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "one\ntwo\n.\n.")
    app.ring_add(&a, id)
    doc := store.store_doc(&a.docs, id)

    txt.doc_set_spans(doc, [][2]txt.Pos{{{0, 0}, {0, 3}}, {{1, 0}, {1, 3}}})
    app.handle_chord(&a, chord("AB02", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "\n\n.\n.")

    txt.doc_set_spans(doc, [][2]txt.Pos{{{2, 1}, {2, 1}}, {{3, 1}, {3, 1}}})
    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "\n\n.one\n.two")
}

// --- the ring ---
//
// `edit.paste` always takes the clipboard, so the ring never stands between ctrl+v and what
// another program put there. `edit.paste_cycle` is the only reader of anything past the head,
// and it works by undoing the paste it is replacing.

@(test)
paste_cycle_walks_back_through_the_ring :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "")
    app.ring_add(&a, id)
    app.clip_set(&a, "one")
    app.clip_set(&a, "two") // newest first, so this is the head

    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    testing.expect_value(t, doc_text(&a, id), "two")

    app.handle_chord(&a, chord("AB04", {.Ctrl, .Shift}))
    testing.expect_value(t, doc_text(&a, id), "one")

    // Past the end it wraps, which is what makes repeating the chord a walk and not a dead end.
    app.handle_chord(&a, chord("AB04", {.Ctrl, .Shift}))
    testing.expect_value(t, doc_text(&a, id), "two")
}

// A cycle only means anything straight after a paste. Any other verb puts the mark down, which
// is what keeps the chord config rather than a mode you can be stuck in.
@(test)
another_verb_puts_the_paste_mark_down :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "")
    app.ring_add(&a, id)
    app.clip_set(&a, "one")
    app.clip_set(&a, "two")

    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    app.handle_chord(&a, chord("LEFT")) // a caret move, and the mark goes down with it
    app.handle_chord(&a, chord("AB04", {.Ctrl, .Shift}))
    testing.expect_value(t, doc_text(&a, id), "two")
    testing.expect_value(t, a.message, "edit.paste_cycle: nothing was just pasted")

    // Typing puts it down too, by the same rule and through a different funnel.
    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    app.text_input(&a, 'x')
    app.handle_chord(&a, chord("AB04", {.Ctrl, .Shift}))
    testing.expect_value(t, a.message, "edit.paste_cycle: nothing was just pasted")
}

// A one-rune paste can coalesce into the typing before it, and a paste that cannot be undone
// on its own cannot be cycled — the branch doc_undo_depth exists to feed.
@(test)
a_coalesced_paste_cannot_cycle :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "")
    app.ring_add(&a, id)
    app.clip_set(&a, "older")
    app.clip_set(&a, "y")

    txt.doc_insert_rune(store.store_doc(&a.docs, id), 'a') // an open typing step
    app.handle_chord(&a, chord("AB04", {.Ctrl})) // "y" joins the 'a' as one undo step
    app.handle_chord(&a, chord("AB04", {.Ctrl, .Shift}))
    testing.expect_value(t, doc_text(&a, id), "ay")
    testing.expect_value(t, a.message, "edit.paste_cycle: nothing was just pasted")
}

// Nothing to walk to says so rather than pasting the same thing again: a bound chord that
// quietly does nothing is the thing §8 exists to prevent.
@(test)
a_cycle_with_one_entry_reports :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    id := scratch_doc(&a, "note", "")
    app.ring_add(&a, id)
    app.clip_set(&a, "only")

    app.handle_chord(&a, chord("AB04", {.Ctrl}))
    app.handle_chord(&a, chord("AB04", {.Ctrl, .Shift}))
    testing.expect_value(t, doc_text(&a, id), "only")
    testing.expect_value(t, a.message, "edit.paste_cycle: the ring holds one entry")
}

// The ring drops its oldest rather than growing without end.
@(test)
the_ring_is_capped :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    for i in 0 ..< app.CLIP_RING + 4 {
        app.clip_set(&a, fmt.tprintf("%d", i))
    }
    testing.expect_value(t, len(a.clips), app.CLIP_RING)
    testing.expect_value(t, app.clip_head(&a).text, fmt.tprintf("%d", app.CLIP_RING + 3))
}

// Copying the same text twice leaves ONE entry, so a cycle never has a step that changes
// nothing on screen.
@(test)
a_repeated_copy_replaces_the_head :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    app.clip_set(&a, "same")
    app.clip_set(&a, "same")
    testing.expect_value(t, len(a.clips), 1)

    app.clip_set(&a, "other")
    app.clip_set(&a, "same")
    testing.expect_value(t, len(a.clips), 3) // not adjacent, so both "same" entries stand
}

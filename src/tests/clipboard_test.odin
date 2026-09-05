package tests

import "core:os"
import "core:testing"
import "../store"
import "../txt"
import app "../oket"

// The system clipboard is the copy path in both directions (PLAN.md §8): what is copied here
// pastes into a browser, and a browser's copy pastes here. These gate the GLFW half of txt's
// doc_copy/doc_cut/doc_paste and nothing else.
//
// A test has no window, so GLFW answers nothing and `a.clip` is what clip_get falls back to.
// That fallback is the shipped path on X11 with the selection dropped, not a test hook.

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
    testing.expect_value(t, a.clip, "hello")
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
    testing.expect_value(t, a.clip, "world")
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
    testing.expect_value(t, a.clip, "one\n")
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
    testing.expect(t, a.clip != "", "a listing row should reach the clipboard")

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
    testing.expect_value(t, a.clip, "one")
    testing.expect_value(t, doc_text(&a, id), "\ntwo")
}

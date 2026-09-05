package tests

import "core:strings"
import "core:testing"
import "../input"
import "../store"
import "../txt"
import app "../oket"

// Search, and almost none of it is here: `doc_find` and `doc_find_all` are txt's and already
// tested. What these gate is the two SHAPES a hit takes.
//
// A hit is a selection, so `:find` needs no highlight of its own — and N selections take a typed
// rune as one commit, which is why there is no replace verb anywhere.

@(private = "file")
find_app :: proc(t: ^testing.T, text: string) -> (a: app.App, id: store.Id, ok: bool) {
    a = bare_app(60, 10) or_return
    id = scratch_doc(&a, "note.txt", text)
    app.ring_add(&a, id)
    return a, id, true
}

@(test)
find_selects_every_match_and_typing_replaces_them :: proc(t: ^testing.T) {
    a, id, ok := find_app(t, "foo one\nfoo two\nbar foo")
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_exec(&a, ":find foo")
    doc := store.store_doc(&a.docs, id)
    testing.expect_value(t, len(doc.cursors), 3)
    testing.expect(t, strings.contains(a.message, "3 matches"), a.message)

    // The whole reason a hit is a selection: the three take one insert as ONE commit, so
    // find-and-replace needs no replace verb. Through txt rather than a chord, because a rune
    // goes to the document's owner (§7) and a scratch document has none — the editor's typing
    // ends in this same call.
    txt.doc_insert_text(doc, "X")
    testing.expect_value(t, doc_text(&a, id), "X one\nX two\nbar X")
}

// The primary is the first hit at or after point, not the first in the file: a search from
// halfway down must not scroll the document out from under you.
@(test)
find_lands_on_the_hit_after_point :: proc(t: ^testing.T) {
    a, id, ok := find_app(t, "hit\n.\n.\nhit\n.\nhit")
    if !ok {
        return
    }
    defer close_app(&a)

    doc := store.store_doc(&a.docs, id)
    txt.doc_set_head(doc, {3, 0}, false)
    app.point_sync(&a)

    app.cl_exec(&a, ":find hit")
    testing.expect_value(t, doc.cursors[doc.primary].head.line, 3)
}

// F3 and shift+F3 step, and stepping collapses: holding every match and walking them one at a
// time are two different things to be looking at.
@(test)
f3_steps_through_the_matches :: proc(t: ^testing.T) {
    a, id, ok := find_app(t, "hit\n.\nhit\n.\nhit")
    if !ok {
        return
    }
    defer close_app(&a)

    f3, _ := input.key_code("FK03")
    doc := store.store_doc(&a.docs, id)
    txt.doc_set_head(doc, {0, 0}, false)
    app.point_sync(&a)
    app.cl_exec(&a, ":find hit")

    app.handle_chord(&a, {f3, {}, 0})
    testing.expect_value(t, len(doc.cursors), 1)
    testing.expect_value(t, doc.cursors[0].head.line, 2)

    app.handle_chord(&a, {f3, {}, 0})
    testing.expect_value(t, doc.cursors[0].head.line, 4)

    // And wrapping is txt's, so the fifth step is the first hit again.
    app.handle_chord(&a, {f3, {}, 0})
    testing.expect_value(t, doc.cursors[0].head.line, 0)

    // Back from the START of the selection, or a step back would find the hit it is standing on.
    app.handle_chord(&a, {f3, {.Shift}, 0})
    testing.expect_value(t, doc.cursors[0].head.line, 4)
}

// The term outlives the command line, which is the whole reason it is app state.
@(test)
f3_before_any_find_says_what_to_type :: proc(t: ^testing.T) {
    a, _, ok := find_app(t, "anything")
    if !ok {
        return
    }
    defer close_app(&a)

    f3, _ := input.key_code("FK03")
    app.handle_chord(&a, {f3, {}, 0})
    testing.expect(t, strings.contains(a.message, ":find"), a.message)
}

// No pattern at all is usage, not a no-op with no answer.
@(test)
find_without_a_pattern_shows_usage :: proc(t: ^testing.T) {
    a, _, ok := find_app(t, "anything")
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_exec(&a, ":find")
    testing.expect(t, strings.contains(a.message, ":find <text>"), a.message)
}

@(test)
find_with_no_match_says_so_and_changes_nothing :: proc(t: ^testing.T) {
    a, id, ok := find_app(t, "one\ntwo")
    if !ok {
        return
    }
    defer close_app(&a)

    doc := store.store_doc(&a.docs, id)
    before := len(doc.cursors)
    app.cl_exec(&a, ":find zzz")
    testing.expect(t, strings.contains(a.message, "no match"), a.message)
    testing.expect_value(t, len(doc.cursors), before)
}

// A search is a jump, so ctrl+alt+left goes back to what you were reading.
@(test)
a_find_is_a_jump :: proc(t: ^testing.T) {
    a, id, ok := find_app(t, "a\n.\n.\n.\n.\n.\nfoo")
    if !ok {
        return
    }
    defer close_app(&a)

    doc := store.store_doc(&a.docs, id)
    txt.doc_set_head(doc, {0, 0}, false)
    app.point_sync(&a)

    app.cl_exec(&a, ":find foo")
    testing.expect_value(t, doc.cursors[doc.primary].head.line, 6)

    app.handle_chord(&a, chord("LEFT", {.Ctrl, .Alt}))
    testing.expect_value(t, app.ring_focused(&a).view.point.head.line, 0)

    // And forward retraces it. The entry ahead shares the SLOT, so only the point part of
    // jump_take's already-standing test lets it land.
    app.handle_chord(&a, chord("RGHT", {.Ctrl, .Alt}))
    testing.expect_value(t, app.ring_focused(&a).view.point.head.line, 6)
}

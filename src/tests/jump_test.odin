package tests

import "core:testing"
import "core:strings"
import "../input"
import "../store"
import "../txt"
import app "../oket"

// The jump ring: where you have been, walked back through. It is written at ONE place —
// `ring_move` — and read by two verbs.
//
// An entry is the viewport and not a position (PLAN.md §11), so a jump that lands on the line
// but not the screen is a jump you would have to redo by hand.

@(private = "file")
ctrl_alt :: proc(name: string) -> input.Chord {
    return chord(name, {.Ctrl, .Alt})
}

@(private = "file")
three_slots :: proc(t: ^testing.T) -> (a: app.App, ok: bool) {
    a = bare_app(40, 6) or_return
    for name in ([?]string{"one.txt", "two.txt", "three.txt"}) {
        app.ring_add(&a, scratch_doc(&a, name, "a\nb\nc\nd\ne\nf\ng\nh"))
    }
    return a, true
}

@(test)
jump_back_walks_the_way_you_came :: proc(t: ^testing.T) {
    a, ok := three_slots(t)
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("AE01", {.Alt})) // alt+1
    app.handle_chord(&a, chord("AE02", {.Alt})) // alt+2
    app.handle_chord(&a, chord("AE03", {.Alt})) // alt+3
    testing.expect_value(t, app.ring_slot(&a), 3)

    app.handle_chord(&a, ctrl_alt("LEFT"))
    testing.expect_value(t, app.ring_slot(&a), 2)
    app.handle_chord(&a, ctrl_alt("LEFT"))
    testing.expect_value(t, app.ring_slot(&a), 1)

    // And forward retraces it, including back to the slot you were standing on when you started
    // walking — which only works because stepping back records that one first.
    app.handle_chord(&a, ctrl_alt("RGHT"))
    testing.expect_value(t, app.ring_slot(&a), 2)
    app.handle_chord(&a, ctrl_alt("RGHT"))
    testing.expect_value(t, app.ring_slot(&a), 3)
}

// Both ends report. A bound chord that quietly does nothing is what §8 exists to prevent.
//
// ONE slot, because opening a document is itself a jump: three_slots above already has a ring
// behind it, and an empty one is the only way to stand at both ends at once.
@(test)
the_ends_of_the_ring_say_so :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    app.ring_add(&a, scratch_doc(&a, "only.txt", "a\nb"))

    app.handle_chord(&a, ctrl_alt("LEFT"))
    testing.expect(t, strings.contains(a.message, "further back"), a.message)

    app.handle_chord(&a, ctrl_alt("RGHT"))
    testing.expect(t, strings.contains(a.message, "further on"), a.message)
}

// A new jump abandons the branch you had walked back out of, which is what stops the ring
// growing a tree nobody can see.
@(test)
a_new_jump_drops_the_forward_half :: proc(t: ^testing.T) {
    a, ok := three_slots(t)
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("AE01", {.Alt}))
    app.handle_chord(&a, chord("AE02", {.Alt}))
    app.handle_chord(&a, chord("AE03", {.Alt}))
    app.handle_chord(&a, ctrl_alt("LEFT")) // to 2, with 3 ahead of us
    testing.expect_value(t, app.ring_slot(&a), 2)

    app.handle_chord(&a, chord("AE01", {.Alt})) // a jump of its own
    app.handle_chord(&a, ctrl_alt("RGHT"))
    testing.expect(t, strings.contains(a.message, "further on"), a.message)
}

// The cap drops the FAR end: a ring past JUMP_MAX still records, and still walks back.
@(test)
a_full_ring_forgets_the_far_end :: proc(t: ^testing.T) {
    a, ok := three_slots(t)
    if !ok {
        return
    }
    defer close_app(&a)

    for i in 0 ..< 2 * app.JUMP_MAX {
        app.handle_chord(&a, chord(i % 2 == 0 ? "AE01" : "AE02", {.Alt}))
    }
    testing.expect_value(t, len(a.jumps), app.JUMP_MAX)

    app.handle_chord(&a, ctrl_alt("LEFT"))
    testing.expect_value(t, app.ring_slot(&a), 1)
}

// The whole point of recording the viewport: a jump puts the SCREEN back, not just the caret.
@(test)
a_jump_restores_the_viewport :: proc(t: ^testing.T) {
    a, ok := three_slots(t)
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("AE01", {.Alt}))
    s := app.ring_focused(&a)
    doc := store.store_doc(&a.docs, s.doc)
    txt.doc_set_head(doc, {6, 1}, false)
    app.point_sync(&a)
    s.view.top = 4

    app.handle_chord(&a, chord("AE02", {.Alt}))
    app.handle_chord(&a, ctrl_alt("LEFT"))

    back := app.ring_focused(&a)
    testing.expect_value(t, app.ring_slot(&a), 1)
    testing.expect_value(t, back.view.top, 4)
    testing.expect_value(t, back.view.point.head, txt.Pos{6, 1})
}

// Text moves under a ring. An entry pointing past the end of a document that has since shrunk
// lands at the end of it rather than off it.
@(test)
a_jump_into_shrunk_text_is_clamped :: proc(t: ^testing.T) {
    a, ok := three_slots(t)
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("AE01", {.Alt}))
    s := app.ring_focused(&a)
    doc := store.store_doc(&a.docs, s.doc)
    txt.doc_set_head(doc, {7, 0}, false)
    app.point_sync(&a)

    app.handle_chord(&a, chord("AE02", {.Alt}))
    txt.doc_set_text(store.store_doc(&a.docs, s.doc), "a\nb")
    app.handle_chord(&a, ctrl_alt("LEFT"))

    back := app.ring_focused(&a)
    testing.expect(t, back.view.point.head.line <= 1, "a stale entry landed off the end")
}

// A slot that closed under an entry is skipped, not refused: the ring outlives what is in it.
@(test)
a_closed_slot_is_skipped :: proc(t: ^testing.T) {
    a, ok := three_slots(t)
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("AE01", {.Alt}))
    app.handle_chord(&a, chord("AE02", {.Alt}))
    app.handle_chord(&a, chord("AE03", {.Alt}))
    app.ring_close(&a, 2)

    // Back would land on 2, which is gone, so the entry is dropped and the walk carries on.
    app.handle_chord(&a, ctrl_alt("LEFT"))
    testing.expect(t, app.ring_slot(&a) != 2, "a closed slot was jumped into")
    testing.expect(t, app.ring_slot(&a) != 3, "jump.back landed where it started")
}

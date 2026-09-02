package tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "../desc"
import "../store"
import "../txt"

// Stage 2's registry half: ids that go stale rather than dangle, and the single write point
// that a transaction either lands on whole or is dropped from.

@(private = "file")
content :: proc(s: ^store.Store, id: store.Id) -> string {
    return txt.doc_string(store.store_doc(s, id), context.temp_allocator)
}

@(test)
store_open_gives_independent_docs :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)

    a := store.store_open(&s, "first")
    b := store.store_open(&s, "second")
    testing.expect(t, a != b)
    testing.expect_value(t, content(&s, a), "first")
    testing.expect_value(t, content(&s, b), "second")
}

// The failure a bare slot index would turn into silent corruption: an id kept across a close,
// used after the slot is handed to someone else.
@(test)
store_id_goes_stale_on_close :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)

    old := store.store_open(&s, "gone")
    testing.expect(t, store.store_close(&s, old))
    testing.expect(t, !store.store_is_open(&s, old))
    testing.expect(t, store.store_doc(&s, old) == nil)
    testing.expect(t, !store.store_close(&s, old), "closing twice must not succeed")

    reused := store.store_open(&s, "different")
    testing.expectf(
        t,
        reused.slot == old.slot,
        "the slot should have been taken again, got %d and not %d",
        reused.slot,
        old.slot,
    )
    testing.expect(t, !store.store_is_open(&s, old), "the old id must not reach the new document")
    testing.expect_value(t, content(&s, reused), "different")
}

@(test)
store_submit_applies_at_the_current_gen :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "hello")

    gen, ok := store.store_gen(&s, id)
    testing.expect(t, ok)
    store.store_submit(&s, id, gen, {txt.Edit{lo = 5, hi = 5, text = " world"}})
    testing.expectf(
        t,
        content(&s, id) == "hello",
        "a submit landed before the drain: %q",
        content(&s, id),
    )

    applied, stale := store.store_drain(&s)
    testing.expect_value(t, applied, 1)
    testing.expect_value(t, stale, 0)
    testing.expect_value(t, content(&s, id), "hello world")

    now, _ := store.store_gen(&s, id)
    testing.expect(t, now > gen, "an applied transaction must move the generation")
}

// The rebase case. The transaction is dropped whole rather than merged, because its offsets
// describe a document its author never saw.
@(test)
store_submit_at_a_stale_gen_is_dropped :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "hello")

    gen, _ := store.store_gen(&s, id)
    txt.doc_apply(store.store_doc(&s, id), {txt.Edit{lo = 0, hi = 0, text = "oh "}})
    store.store_submit(&s, id, gen, {txt.Edit{lo = 5, hi = 5, text = " world"}})

    applied, stale := store.store_drain(&s)
    testing.expect_value(t, applied, 0)
    testing.expect_value(t, stale, 1)
    testing.expect_value(t, content(&s, id), "oh hello")
}

// The slot is reused before the drain runs. The seq is what keeps the dead transaction off
// the new document, whose gen happens to match the one it was written against.
@(test)
store_stale_submit_misses_a_reused_slot :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "old")

    gen, _ := store.store_gen(&s, id)
    store.store_submit(&s, id, gen, {txt.Edit{lo = 0, hi = 0, text = "x"}})
    store.store_close(&s, id)
    reused := store.store_open(&s, "new")
    testing.expect_value(t, reused.slot, id.slot)

    applied, stale := store.store_drain(&s)
    testing.expect_value(t, applied, 0)
    testing.expect_value(t, stale, 1)
    testing.expect_value(t, content(&s, reused), "new")
}

@(test)
store_submit_to_a_closed_doc_is_dropped :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "doomed")

    gen, _ := store.store_gen(&s, id)
    store.store_submit(&s, id, gen, {txt.Edit{lo = 0, hi = 0, text = "x"}})
    store.store_close(&s, id)

    applied, stale := store.store_drain(&s)
    testing.expect_value(t, applied, 0)
    testing.expect_value(t, stale, 1)
}

// Two transactions in one drain: the first moves the generation, so the second is stale by the
// time it is reached even though both were written against the same one.
@(test)
store_drain_serialises_one_generation_at_a_time :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "base")

    gen, _ := store.store_gen(&s, id)
    store.store_submit(&s, id, gen, {txt.Edit{lo = 4, hi = 4, text = "-one"}})
    store.store_submit(&s, id, gen, {txt.Edit{lo = 4, hi = 4, text = "-two"}})

    applied, stale := store.store_drain(&s)
    testing.expect_value(t, applied, 1)
    testing.expect_value(t, stale, 1)
    testing.expect_value(t, content(&s, id), "base-one")
}

// A descriptor is versioned state, not registration (§5): it rides in the transaction and
// lands at the same point the edits do, so a reader never sees text from one generation
// described by another's descriptor.
@(test)
store_descriptor_travels_with_the_generation :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "one\ntwo")

    opened := store.store_descriptor(&s, id)
    defer desc.release(opened)
    testing.expect_value(t, opened.numbers, desc.Numbers.Off)
    testing.expect_value(t, opened.tab_width, 4)

    gen, _ := store.store_gen(&s, id)
    published := desc.new_from({numbers = .Relative, wrap = .Word, tab_width = 8})
    defer desc.release(published)
    store.store_submit(&s, id, gen, {txt.Edit{lo = 3, hi = 3, text = "!"}}, published)

    applied, _ := store.store_drain(&s)
    testing.expect_value(t, applied, 1)
    testing.expect_value(t, content(&s, id), "one!\ntwo")

    now := store.store_descriptor(&s, id)
    defer desc.release(now)
    testing.expect_value(t, now.numbers, desc.Numbers.Relative)
    testing.expect_value(t, now.wrap, desc.Wrap.Word)
    testing.expect_value(t, now.tab_width, 8)
    testing.expect(t, opened.numbers == .Off, "the descriptor a reader holds was rewritten")
}

// The transaction is dropped whole, descriptor included. A descriptor that landed while its
// edits did not would describe text nobody wrote.
@(test)
store_stale_submit_drops_its_descriptor :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "hello")

    gen, _ := store.store_gen(&s, id)
    published := desc.new_from({numbers = .Absolute})
    defer desc.release(published)
    txt.doc_apply(store.store_doc(&s, id), {txt.Edit{lo = 0, hi = 0, text = "oh "}})
    store.store_submit(&s, id, gen, nil, published)

    _, stale := store.store_drain(&s)
    testing.expect_value(t, stale, 1)

    now := store.store_descriptor(&s, id)
    defer desc.release(now)
    testing.expect_value(t, now.numbers, desc.Numbers.Off)
}

// The read path's whole promise: a snapshot is a reference to bytes, not a view of a document,
// so closing the document underneath it changes nothing.
@(test)
store_snapshot_outlives_the_document :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "alpha\nbeta\n")

    snap := store.store_snapshot(&s, id)
    defer txt.snapshot_release(snap)
    testing.expect(t, snap != nil)

    store.store_close(&s, id)
    testing.expect(t, store.store_snapshot(&s, id) == nil)
    testing.expect_value(t, txt.text_line_count(snap), 2)
    testing.expect_value(
        t,
        string(txt.text_read(snap, 0, snap.size, context.temp_allocator)),
        "alpha\nbeta",
    )
}

// Housekeeping belongs to the drain, not the edit path. This is also the case where compaction
// runs with a live snapshot in hand, which is only safe because the arena is refcounted.
@(test)
store_drain_compacts_a_splintered_table :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "seed\n")
    d := store.store_doc(&s, id)

    for i in 0 ..< 3000 {
        at := (i * 7919) % (d.pt.size + 1)
        txt.doc_apply(d, {txt.Edit{lo = at, hi = at, text = fmt.tprintf("<%d>", i % 100)}})
    }
    testing.expect(t, txt.pt_should_compact(&d.pt), "the stress did not splinter the table")

    want := strings.clone(txt.doc_string(d, context.temp_allocator))
    defer delete(want)
    snap := store.store_snapshot(&s, id)
    defer txt.snapshot_release(snap)

    store.store_drain(&s)
    testing.expect(t, !txt.pt_should_compact(&d.pt), "the drain must flatten the table")
    testing.expect_value(t, txt.doc_string(d, context.temp_allocator), want)
    testing.expect_value(
        t,
        string(txt.text_read(snap, 0, snap.size, context.temp_allocator)),
        want,
    )

    // A snapshot taken AFTER the drain must sit in the fresh arena. The cached one would pin
    // the old arena — and everything compaction just reclaimed — for as long as the doc idles.
    fresh := store.store_snapshot(&s, id)
    defer txt.snapshot_release(fresh)
    testing.expect(t, fresh.arena != snap.arena, "the snapshot cache pinned the spent arena")
}

// §10's invariant checks. The one that has state behind it is the generation, and a slot is
// reused: a fresh document opening into one that carried a long history starts at generation
// zero, which is BACKWARDS unless the high-water mark starts again with it.
@(test)
store_check_follows_a_generation_into_a_reused_slot :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "alpha")
    d := store.store_doc(&s, id)
    for _ in 0 ..< 8 {
        txt.doc_apply(d, {txt.Edit{lo = 0, hi = 0, text = "x"}})
    }
    testing.expect(t, store.store_check(&s), "an ordinary document failed the checks")

    store.store_close(&s, id)
    again := store.store_open(&s, "beta")
    testing.expect_value(t, again.slot, id.slot) // the point of the test: the same slot
    testing.expect(t, store.store_check(&s), "a reused slot looked like a generation going back")

    // And the check still catches what it is for.
    store.store_doc(&s, again).magic = 0
    testing.expect(t, !store.store_check(&s), "a smashed header passed")
}

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

// FIELDS RIDE THE TEXT (fields.odin). A span is where a link was drawn, so text moving under it
// has to take it along — otherwise a document that is both a listing and a text field is only
// true for the generation it was published at, and one typed character makes every link on the
// line name bytes that have moved.
@(test)
a_field_follows_the_text_it_was_measured_over :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "top.txt\nsecond")
    gen, _ := store.store_gen(&s, id)
    fields := [?]desc.Field {
        {0, "name", 0, 7, ""},
        {0, "path", 0, 7, "/tmp/top.txt"},
        {1, "name", 0, 6, ""},
    }
    d := desc.new_from({fields = fields[:]})
    store.store_submit(&s, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&s)

    // Typed at the head of the first row: the span grows to hold what was typed — text at
    // either edge of a link belongs to the link — and the value it points at does not move.
    txt.doc_reset_cursor(store.store_doc(&s, id), {0, 0})
    txt.doc_insert_text(store.store_doc(&s, id), "new_")
    read := store.store_descriptor(&s, id)
    defer desc.release(read)
    lo, hi, ok := desc.field_span(read, 0, "name")
    testing.expect(t, ok, "the field went away")
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 11)
    path, _ := desc.field_of(read, 0, "path")
    testing.expect_value(t, path.value, "/tmp/top.txt")
    // The row below it did not move sideways, and it is still on its own line.
    below, _ := desc.field_of(read, 1, "name")
    testing.expect_value(t, below.hi, 6)
}

// A link whose text is gone is GONE. Leaving it would be a span pointing at bytes it no longer
// covers, and a `<path>` that resolves to the wrong row is worse than one that reports.
@(test)
a_field_whose_text_is_deleted_is_dropped :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "top.txt")
    gen, _ := store.store_gen(&s, id)
    fields := [?]desc.Field{{0, "path", 0, 7, "/tmp/top.txt"}}
    d := desc.new_from({fields = fields[:]})
    store.store_submit(&s, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&s)

    txt.doc_apply(store.store_doc(&s, id), {txt.Edit{lo = 0, hi = 7, text = ""}})
    read := store.store_descriptor(&s, id)
    defer desc.release(read)
    _, _, ok := desc.field_span(read, 0, "path")
    testing.expect(t, !ok, "a link survived the text it was drawn over")
}

// A submit that says REGEN is DERIVED text: the carets stay on their rows and the undo log
// goes. Both rules are the one word — there is nothing of the user's in derived text — and
// without the first a tree cannot be walked at all, because every expand would throw point to
// the end of the document.
@(test)
a_regeneration_keeps_the_carets_and_forgets_the_undo :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "one\ntwo")
    gen, _ := store.store_gen(&s, id)
    d := desc.new_from({editable = true})
    store.store_submit(&s, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&s)
    doc := store.store_doc(&s, id)
    txt.doc_reset_cursor(doc, {1, 1})

    gen, _ = store.store_gen(&s, id)
    store.store_submit(&s, id, gen, {txt.Edit{lo = 0, hi = txt.doc_len(doc), text = "one\nsub\ntwo"}},
                       nil, nil, regen = true)
    store.store_drain(&s)
    testing.expect_value(t, doc.cursors[0].head, txt.Pos{1, 1}) // where navigation left it
    testing.expect(t, !txt.doc_undo(doc), "a regeneration left an undo that walks into old rows")

    // The same submit without the word: a keystroke's splice, and its caret follows it.
    gen, _ = store.store_gen(&s, id)
    store.store_submit(&s, id, gen, {txt.Edit{lo = 0, hi = 0, text = "x"}})
    store.store_drain(&s)
    testing.expect_value(t, doc.cursors[0].head, txt.Pos{0, 1})
}

// A descriptor submitted WITH its edits is written against the text those edits make, so its
// spans land already true. Shifting them again through the transaction's own splice is the
// double-fold this catches.
@(test)
a_descriptor_published_with_its_splice_is_not_shifted_by_it :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "old")
    gen, _ := store.store_gen(&s, id)
    fields := [?]desc.Field{{0, "name", 0, 13, ""}}
    d := desc.new_from({fields = fields[:]})
    store.store_submit(&s, id, gen, {txt.Edit{lo = 0, hi = 3, text = "brand-new.txt"}}, d)
    desc.release(d)
    store.store_drain(&s)

    read := store.store_descriptor(&s, id)
    defer desc.release(read)
    lo, hi, ok := desc.field_span(read, 0, "name")
    testing.expect(t, ok, "the field went away")
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 13)
}

// The change log is bounded, and a reader it no longer reaches back to cannot say where the
// spans went. A link that MIGHT point at the wrong thing is worse than none: they all go, and
// the owner republishes when it hears the generation moved.
@(test)
a_field_the_log_no_longer_reaches_is_dropped :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "top.txt")
    gen, _ := store.store_gen(&s, id)
    fields := [?]desc.Field{{0, "path", 0, 7, "/tmp/top.txt"}}
    d := desc.new_from({fields = fields[:]})
    store.store_submit(&s, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&s)

    for _ in 0 ..< txt.DOC_CHANGE_MAX + 1 {
        txt.doc_apply(store.store_doc(&s, id), {txt.Edit{lo = 0, hi = 0, text = "x"}})
    }
    read := store.store_descriptor(&s, id)
    defer desc.release(read)
    _, _, ok := desc.field_span(read, 0, "path")
    testing.expect(t, !ok, "a link outlived the log that could have placed it")
}

// A point rides the transaction it was measured against. The offset describes text a pending
// write is about to make, so a write that loses the race takes its caret with it — otherwise the
// caret lands in a document that write never reached, which is a jump nothing on screen explains.
@(test)
a_point_whose_transaction_was_dropped_does_not_land :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    id := store.store_open(&s, "one\ntwo")
    doc := store.store_doc(&s, id)
    gen, _ := store.store_gen(&s, id)
    txt.doc_reset_cursor(doc, {0, 0})

    // Written against `gen`, and then somebody else moves the document first.
    store.store_submit(&s, id, gen, {txt.Edit{lo = 0, hi = 0, text = "sub\n"}})
    store.store_point(&s, id, 6)
    txt.doc_apply(doc, {txt.Edit{lo = 3, hi = 3, text = "!"}})
    store.store_drain(&s)
    // Where the foreign splice left it, and NOT the {1, 1} the dropped point asked for.
    testing.expect_value(t, doc.cursors[0].head, txt.Pos{0, 4})

    // And a bare move, with nothing pending behind it, still lands. "one!\n" is five bytes, so
    // six is one into the line below it.
    store.store_point(&s, id, 6)
    store.store_drain(&s)
    testing.expect_value(t, doc.cursors[0].head, txt.Pos{1, 1})
}

// A LISTING IS N ROWS AND ONE COMMIT (VIEWS.md §11). A rename over every row lands as one
// transaction past DOC_CHANGE_MAX; a log that drops it tells fields.odin `lost`, which deletes
// every link in the document — one keystroke, and a browser is a listing you can no longer
// follow.
@(test)
every_field_in_a_listing_survives_a_batch :: proc(t: ^testing.T) {
    ROWS :: 300 // past DOC_CHANGE_MAX

    s: store.Store
    defer store.store_destroy(&s)
    rows := strings.builder_make(context.temp_allocator)
    for _ in 0 ..< ROWS {
        strings.write_string(&rows, "name\n")
    }
    id := store.store_open(&s, strings.to_string(rows))
    gen, _ := store.store_gen(&s, id)

    fields := make([]desc.Field, ROWS, context.temp_allocator)
    for i in 0 ..< ROWS {
        fields[i] = desc.Field{i, "name", 0, 4, "/tmp/name"}
    }
    d := desc.new_from({fields = fields})
    store.store_submit(&s, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&s)

    // One typed character on every row at once, which is what a caret per row does.
    doc := store.store_doc(&s, id)
    edits := make([]txt.Edit, ROWS, context.temp_allocator)
    for i in 0 ..< ROWS {
        off := txt.doc_off(doc, txt.Pos{i, 4})
        edits[i] = txt.Edit{lo = off, hi = off, text = "z"}
    }
    txt.doc_apply(doc, edits)

    read := store.store_descriptor(&s, id)
    defer desc.release(read)
    for i in 0 ..< ROWS {
        lo, hi, ok := desc.field_span(read, i, "name")
        if !testing.expectf(t, ok, "row %d lost its link", i) {
            return
        }
        testing.expect_value(t, lo, 0)
        testing.expect_value(t, hi, 5) // text at the edge of a link belongs to the link
    }
}

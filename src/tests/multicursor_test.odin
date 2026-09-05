package tests

import "core:testing"
import "../txt"

// Multi-cursor editing and the commit's cursor policy (VIEWS.md §3, stage 1). Every edit fans
// out to one replacement per cursor, and the two ways that goes wrong are here: carets that
// name the SAME range, which must edit it once, and carets whose ranges OVERLAP, which must not
// edit it twice. The generator is support_test.odin's seeded one, so a failing trial
// reproduces.

@(private = "file")
mk :: proc(s: string) -> txt.Doc {
    d: txt.Doc
    txt.doc_init(&d)
    txt.doc_set_text(&d, s)
    return d
}

@(private = "file")
mk2 :: proc(s: string, a, b: txt.Pos) -> txt.Doc {
    d := mk(s)
    txt.doc_reset_cursor(&d, a)
    txt.doc_add_cursor(&d, b)
    return d
}

@(private = "file")
text :: proc(d: ^txt.Doc) -> string {
    return txt.doc_string(d, context.temp_allocator)
}

// Two carets one byte apart delete one rune each. Both deletions land at the same offset in the
// document they leave behind, so undo must not read them as one.
@(test)
multicursor_backspace_undo :: proc(t: ^testing.T) {
    d := mk2("abcd", {0, 1}, {0, 2})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_backspace(&d))
    testing.expect_value(t, text(&d), "cd")

    testing.expect(t, txt.doc_undo(&d))
    testing.expect_value(t, text(&d), "abcd")
}

// Two carets inside one word: both word-deletes reach back to the same word start, so the word
// goes once. Applying both would eat a rune that neither caret named.
@(test)
multicursor_word_back_overlap :: proc(t: ^testing.T) {
    d := mk2("abcd", {0, 1}, {0, 2})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_delete_word_back(&d))
    testing.expect_value(t, text(&d), "cd")

    testing.expect(t, txt.doc_undo(&d))
    testing.expect_value(t, text(&d), "abcd")
}

// Alt+A leaves a fixed cursor exactly under the free caret. That pair names one range, and a
// typed character must appear once.
@(test)
dropped_anchor_types_once :: proc(t: ^testing.T) {
    d := mk("ab")
    defer txt.doc_destroy(&d)
    txt.doc_reset_cursor(&d, {0, 1})
    txt.doc_drop_anchor(&d)
    testing.expect_value(t, len(d.cursors), 2)

    testing.expect(t, txt.doc_insert_rune(&d, 'X'))
    testing.expect_value(t, text(&d), "aXb")
}

// The same rule, with the two carets disagreeing about their GOAL column: vertical motion off a
// long line leaves a stale one, and a caret placed at that spot computes a fresh one. Only the
// selection decides whether a pair names one range, so this still types once — which is what
// pins goal (and id) out of edit_cursors' key.
@(test)
a_coincident_pair_with_different_goals_types_once :: proc(t: ^testing.T) {
    d := mk("abcdef\nab")
    defer txt.doc_destroy(&d)
    txt.doc_reset_cursor(&d, {0, 6})
    txt.doc_move(&d, .Down) // head clamps to {1, 2}; the goal stays 6
    txt.doc_add_cursor(&d, {1, 2}) // the same spot, goal 2
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect(t, d.cursors[0].goal != d.cursors[1].goal, "the fixture left one goal")

    testing.expect(t, txt.doc_insert_rune(&d, 'X'))
    testing.expect_value(t, text(&d), "abcdef\nabX")
}

// --- the policies (VIEWS.md §3) ---

// .Shift is what a formatter wants: the carets it did not ask about come through carried, not
// collapsed. An indent pushes each one right by what its line gained.
@(test)
shift_policy_carries_carets :: proc(t: ^testing.T) {
    d := mk2("abc\ndef", {0, 1}, {1, 2})
    defer txt.doc_destroy(&d)

    edits := []txt.Edit{{0, 0, "    ", 0, 0}, {4, 4, "    ", 0, 0}}
    testing.expect(t, txt.doc_commit(&d, edits, {policy = .Shift}))
    testing.expect_value(t, text(&d), "    abc\n    def")
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 5})
    testing.expect_value(t, d.cursors[1].head, txt.Pos{1, 6})
}

// The other half of the same rule: a caret INSIDE what a dedent removed lands on the front of
// the splice, and one after it moves back by the delta.
@(test)
shift_policy_dedent :: proc(t: ^testing.T) {
    d := mk2("    abc", {0, 2}, {0, 6})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_commit(&d, {txt.Edit{0, 4, "", 0, 0}}, {policy = .Shift}))
    testing.expect_value(t, text(&d), "abc")
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 0})
    testing.expect_value(t, d.cursors[1].head, txt.Pos{0, 2})
}

// A splice that changes the LINE count: a caret below it rides down, and one on the last
// replaced line rebases its column on the splice's new end.
@(test)
shift_policy_across_lines :: proc(t: ^testing.T) {
    d := mk2("abc\ndef", {1, 2}, {0, 1})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_commit(&d, {txt.Edit{0, 0, "x\ny\n", 0, 0}}, {policy = .Shift}))
    testing.expect_value(t, text(&d), "x\ny\nabc\ndef")
    testing.expect_value(t, d.cursors[0].head, txt.Pos{3, 2})
    testing.expect_value(t, d.cursors[1].head, txt.Pos{2, 1})
}

// .Pin is a regeneration: the whole document is replaced and the caret stays on the ROW
// navigation put it on. Under .Follow it would collapse onto the end of the splice.
@(test)
pin_policy_keeps_the_row :: proc(t: ^testing.T) {
    d := mk("one\ntwo\nthree")
    defer txt.doc_destroy(&d)
    txt.doc_reset_cursor(&d, {2, 3})

    edits := []txt.Edit{{0, txt.doc_len(&d), "AAA\nBBB\nCCCCC", 0, 0}}
    testing.expect(t, txt.doc_commit(&d, edits, {policy = .Pin}))
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{2, 3})
}

// .Set is the author's own answer, clamped into the document the edit left behind.
@(test)
set_policy_takes_the_authors_set :: proc(t: ^testing.T) {
    d := mk("one\ntwo\nthree")
    defer txt.doc_destroy(&d)

    want := []txt.Cursor{{head = {0, 1}, anchor = {0, 1}}, {head = {1, 99}, anchor = {1, 0}}}
    edits := []txt.Edit{{0, txt.doc_len(&d), "xy\nzw", 0, 0}}
    testing.expect(t, txt.doc_commit(&d, edits, {policy = .Set, set = want}))
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 1})
    testing.expect_value(t, d.cursors[1].head, txt.Pos{1, 2}) // clamped to the line's length
    testing.expect_value(t, d.cursors[1].anchor, txt.Pos{1, 0})
}

// --- the primary, across an edit and a merge (CURSORS.md §5, VIEWS.md §12) ---
//
// The set is rebuilt by .Follow and re-SORTED by a merge, so an index says nothing about which
// caret it was. A name does, and the two tests below are the whole of the difference: the
// primary is recovered from the name, not clamped into the range that is left.

// Typing at the bottom caret leaves the primary there, not at index 0, so scroll-follow stays
// with the caret being typed at.
@(test)
the_primary_is_the_caret_that_typed :: proc(t: ^testing.T) {
    d := mk2("one\ntwo\nthree", {0, 0}, {2, 0})
    defer txt.doc_destroy(&d)
    was := d.cursors[d.primary].id
    testing.expect_value(t, d.cursors[d.primary].head, txt.Pos{2, 0})

    testing.expect(t, txt.doc_insert_text(&d, "X"))
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.cursors[d.primary].id, was)
    testing.expect_value(t, d.cursors[d.primary].head, txt.Pos{2, 1})
}

// A merge sorts, and the primary is the caret added LAST: the sort moves its index, so only
// the name can say which caret is still the primary.
@(test)
a_merge_keeps_the_primary_named :: proc(t: ^testing.T) {
    d := mk2("one\ntwo\nthree", {2, 0}, {0, 0})
    defer txt.doc_destroy(&d)
    was := d.cursors[d.primary].id
    testing.expect_value(t, d.primary, 1) // appended last, and it is the TOP line

    txt.doc_move(&d, .Right)
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.primary, 0) // sorted to the front, and still the primary
    testing.expect_value(t, d.cursors[d.primary].id, was)
    testing.expect_value(t, d.cursors[d.primary].head, txt.Pos{0, 1})
}

// Two carets inside one word fuse, and one name has to win. The primary's does, so the caret
// the user is typing at is the one that survives being merged into a neighbour.
@(test)
a_fused_pair_answers_to_the_primary :: proc(t: ^testing.T) {
    d := mk2("abcd", {0, 1}, {0, 2})
    defer txt.doc_destroy(&d)
    was := d.cursors[d.primary].id

    testing.expect(t, txt.doc_delete_word_back(&d))
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].id, was)
    testing.expect_value(t, d.primary, 0)
}

// A name is never reused, so a caret that is gone cannot come back as somebody else's. Every
// cursor the kernel places has one; 0 only ever arrives from outside (oket.h).
@(test)
every_caret_is_named :: proc(t: ^testing.T) {
    d := mk2("one\ntwo\nthree", {0, 0}, {2, 0})
    defer txt.doc_destroy(&d)
    txt.doc_add_cursor(&d, {1, 0})

    seen: map[u32]bool
    defer delete(seen)
    for c in d.cursors {
        testing.expect(t, c.id != 0)
        testing.expect(t, !seen[c.id])
        seen[c.id] = true
    }
    testing.expect_value(t, len(seen), 3)
}

// A set that arrives unnamed is named on the way in, and one that arrives named keeps what it
// sent — which is what lets a plugin hand the same caret back next frame.
@(test)
an_unnamed_set_is_named_on_arrival :: proc(t: ^testing.T) {
    d := mk("one\ntwo\nthree")
    defer txt.doc_destroy(&d)

    want := []txt.Cursor{
        {head = {0, 1}, anchor = {0, 1}},
        {head = {1, 1}, anchor = {1, 1}, id = 900},
    }
    txt.doc_set_cursors(&d, want, 0)
    testing.expect(t, d.cursors[0].id != 0)
    testing.expect_value(t, d.cursors[1].id, u32(900))

    // The counter is past what arrived, so the next caret the kernel places cannot collide.
    txt.doc_add_cursor(&d, {2, 0})
    testing.expect(t, d.cursors[len(d.cursors) - 1].id > 900)
}

// The top of the range. A set may arrive naming any u32, and the counter pushed past the
// highest one must still hand out a name rather than wrapping onto "unnamed".
@(test)
the_counter_never_hands_out_zero :: proc(t: ^testing.T) {
    d := mk("one\ntwo\nthree")
    defer txt.doc_destroy(&d)

    txt.doc_set_cursors(&d, {{head = {0, 0}, anchor = {0, 0}, id = max(u32)}}, 0)
    txt.doc_add_cursor(&d, {1, 0})
    testing.expect(t, d.cursors[len(d.cursors) - 1].id != 0)
}

// --- the property ---

@(private = "file")
EDIT_OPS :: 40

@(private = "file")
TRIALS :: 200

@(private = "file")
START :: "one two\nthree four\n\nfïve six\nseven"

// Undo far enough and the document is the one you started with; redo forward and it is the one
// you ended with. Nothing else is asserted, because nothing else has to be: any edit that loses
// or duplicates bytes under a caret arrangement breaks the round trip. Multi-byte runes are in
// the corpus so a caret landing mid-rune is exercised too.
@(test)
multicursor_undo_roundtrip :: proc(t: ^testing.T) {
    seed: u64 = RNG_SEED

    for trial in 0 ..< TRIALS {
        d := mk(START)
        defer txt.doc_destroy(&d)

        for _ in 0 ..< EDIT_OPS {
            scatter_cursors(&d, &seed)
            random_edit(&d, &seed)
        }
        end := txt.doc_string(&d, context.temp_allocator)

        for txt.doc_undo(&d) {}
        testing.expectf(t, text(&d) == START, "trial %d: undo left %q", trial, text(&d))

        for txt.doc_redo(&d) {}
        testing.expectf(t, text(&d) == end, "trial %d: redo left %q", trial, text(&d))
    }
}

// One to four carets at random positions, each with an even chance of a selection running to
// another random position. doc_clamp_pos does the snapping, as it does for a real pointer.
@(private = "file")
scatter_cursors :: proc(d: ^txt.Doc, seed: ^u64) {
    txt.doc_reset_cursor(d, random_pos(d, seed))
    for _ in 0 ..< rng_next(seed, 3) {
        txt.doc_add_cursor(d, random_pos(d, seed))
    }
    if rng_next(seed, 2) == 0 {
        txt.doc_set_head(d, random_pos(d, seed), true)
    }
    if rng_next(seed, 8) == 0 {
        txt.doc_drop_anchor(d) // the coincident pair
    }
}

@(private = "file")
random_pos :: proc(d: ^txt.Doc, seed: ^u64) -> txt.Pos {
    line := rng_next(seed, txt.doc_line_count(d))
    return {line, rng_next(seed, txt.doc_line_len(d, line) + 1)}
}

@(private = "file")
RUNES := []rune{'a', ' ', '(', 'é'}

@(private = "file")
TEXTS := []string{"xy", "p\nq", "  "}

@(private = "file")
random_edit :: proc(d: ^txt.Doc, seed: ^u64) {
    switch rng_next(seed, 8) {
    case 0:
        txt.doc_insert_rune(d, RUNES[rng_next(seed, len(RUNES))])
    case 1:
        txt.doc_insert_text(d, TEXTS[rng_next(seed, len(TEXTS))])
    case 2:
        txt.doc_newline(d)
    case 3:
        txt.doc_backspace(d)
    case 4:
        txt.doc_delete(d)
    case 5:
        txt.doc_delete_word_back(d)
    case 6:
        txt.doc_delete_word_forward(d)
    case 7:
        txt.doc_cut(d)
    }
}

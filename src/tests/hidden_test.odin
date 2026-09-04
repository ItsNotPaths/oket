package tests

import "core:testing"
import "../txt"

// VIEWS.md stage 5's gate: motion over a document with runs that are not on screen.
//
// The list is supplied HERE, by hand, because nothing produces one yet. Motion runs in
// original coordinates and is told one thing about the view: which ranges it may not land in.
// No map, no derived document, no pipeline.

@(private = "file")
mk :: proc(s: string, at := txt.Pos{}) -> txt.Doc {
    d: txt.Doc
    txt.doc_init(&d)
    txt.doc_set_text(&d, s)
    txt.doc_reset_cursor(&d, at)
    return d
}

@(private = "file")
head :: proc(d: ^txt.Doc) -> txt.Pos {
    return d.cursors[d.primary].head
}

// Six lines with 2..4 folded away: the deletion runs from the end of line 1 to the end of
// line 4, which is the shape a fold takes — the header line stays and the break that made line
// 2 a row of its own is gone.
@(private = "file")
FOLD_2_TO_4 :: []txt.Range{{{1, 3}, {4, 3}}}

// --- vertical ---

@(test)
down_skips_a_hidden_run :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc\nddd\neee\nfff", {1, 0})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Down, hidden = FOLD_2_TO_4)
    testing.expect_value(t, head(&d), txt.Pos{5, 0})
}

@(test)
up_skips_a_hidden_run :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc\nddd\neee\nfff", {5, 0})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Up, hidden = FOLD_2_TO_4)
    testing.expect_value(t, head(&d), txt.Pos{1, 0})
}

// A hidden line is not a line the count spends: three visible lines down is three rows down on
// screen, which is what a page motion has to mean.
@(test)
a_count_walks_visible_lines_only :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc\nddd\neee\nfff\nggg", {0, 0})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Down, count = 2, hidden = FOLD_2_TO_4)
    testing.expect_value(t, head(&d), txt.Pos{5, 0})
}

// Nothing visible below: the caret stays, the same way an arrow on the last line already did.
@(test)
down_into_a_fold_that_runs_to_the_end_stays :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc", {0, 1})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Down, hidden = []txt.Range{{{0, 3}, {2, 3}}})
    testing.expect_value(t, head(&d), txt.Pos{0, 1})
}

// --- horizontal ---

// A hidden run is zero cells wide, so one press crosses it: from the cell before the run to the
// cell after it. Two presses would mean the fold had an inside to sit in, and it has none.
@(test)
right_steps_over_a_fold_as_one_move :: proc(t: ^testing.T) {
    d := mk("abcXXXdef", {0, 3})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Right, hidden = []txt.Range{{{0, 3}, {0, 6}}})
    testing.expect_value(t, head(&d), txt.Pos{0, 7})
}

@(test)
left_steps_over_a_fold_as_one_move :: proc(t: ^testing.T) {
    d := mk("abcXXXdef", {0, 7})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Left, hidden = []txt.Range{{{0, 3}, {0, 6}}})
    testing.expect_value(t, head(&d), txt.Pos{0, 3}) // the run's near edge, one cell over
}

// The line break is inside the run, so leftward motion out of line 5 arrives at the end of
// line 1 and not at the end of line 4.
@(test)
left_over_a_line_run_lands_on_the_visible_line :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc\nddd\neee\nfff", {5, 0})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Left, hidden = FOLD_2_TO_4)
    testing.expect_value(t, head(&d), txt.Pos{1, 3})
}

// Two runs that meet are one obstacle: the clamp out of the second lands in the first, and the
// press must not stop there.
@(test)
touching_runs_cross_as_one :: proc(t: ^testing.T) {
    d := mk("abcXXYYdef", {0, 8})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Left, hidden = []txt.Range{{{0, 3}, {0, 5}}, {{0, 5}, {0, 7}}})
    testing.expect_value(t, head(&d), txt.Pos{0, 3})
}

// --- the ends of the document ---

@(test)
doc_end_clamps_to_the_last_visible_line :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc", {0, 0})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Doc_End, hidden = []txt.Range{{{0, 3}, {2, 3}}})
    testing.expect_value(t, head(&d), txt.Pos{0, 3})
}

@(test)
doc_start_clamps_past_a_fold_at_the_top :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc", {2, 0})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Doc_Start, hidden = []txt.Range{{{0, 0}, {1, 2}}})
    testing.expect_value(t, head(&d), txt.Pos{1, 2})
}

// --- the arms §7 calls unaffected ---

// End is line-local and unaffected while the fold is not INLINE. When the fold reaches the
// line's end, that end IS the run's hi edge — the caret lands there and must not be dragged
// to lo.
@(test)
end_onto_an_inline_run_stays_on_its_far_edge :: proc(t: ^testing.T) {
    d := mk("abcXXX\ndef", {0, 1})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .End, hidden = []txt.Range{{{0, 3}, {0, 6}}})
    testing.expect_value(t, head(&d), txt.Pos{0, 6})
}

// The clamp extends rather than places: pushing a landing out of a run must not eat the
// anchor a shift-motion is holding.
@(test)
a_clamped_landing_keeps_its_selection :: proc(t: ^testing.T) {
    d := mk("abcde\nabXXe\nabcde", {0, 3})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Down, select = true, hidden = []txt.Range{{{1, 2}, {1, 4}}})
    c := d.cursors[d.primary]
    testing.expect_value(t, c.anchor, txt.Pos{0, 3})
    testing.expect_value(t, c.head, txt.Pos{1, 2})
}

// A vertical landing inside an inline run is pushed to an edge, and the goal column survives
// it: both edges are one cell on screen, so the caret did not move sideways and the next Down
// must still know which column it is walking.
@(test)
a_landing_inside_an_inline_run_keeps_its_goal :: proc(t: ^testing.T) {
    d := mk("abcde\nabXXe\nabcde", {0, 3})
    defer txt.doc_destroy(&d)

    hidden := []txt.Range{{{1, 2}, {1, 4}}}
    txt.doc_move(&d, .Down, hidden = hidden)
    testing.expect_value(t, head(&d), txt.Pos{1, 2})

    txt.doc_move(&d, .Down, hidden = hidden)
    testing.expect_value(t, head(&d), txt.Pos{2, 3})
}

// --- the whole set ---

// The list is the document's, not the caret's: every cursor in the set skips the same run.
@(test)
every_caret_skips_the_same_run :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc\nddd\neee\nfff", {1, 0})
    defer txt.doc_destroy(&d)

    txt.doc_add_cursor(&d, {1, 2})
    txt.doc_move(&d, .Down, hidden = FOLD_2_TO_4)
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{5, 0})
    testing.expect_value(t, d.cursors[1].head, txt.Pos{5, 2})
}

// An empty list is every document there is until a stage produces one, and it must move
// exactly like plain motion.
@(test)
an_empty_list_moves_the_way_it_always_did :: proc(t: ^testing.T) {
    d := mk("aaa\nbbb\nccc", {1, 1})
    defer txt.doc_destroy(&d)

    txt.doc_move(&d, .Down, hidden = nil)
    testing.expect_value(t, head(&d), txt.Pos{2, 1})
    txt.doc_move(&d, .Doc_End, hidden = nil)
    testing.expect_value(t, head(&d), txt.Pos{2, 3})
    txt.doc_move(&d, .Left, hidden = nil)
    testing.expect_value(t, head(&d), txt.Pos{2, 2})
}

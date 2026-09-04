package tests

import "core:testing"
import "../desc"
import "../gfx"
import "../txt"
import "../view"

// VIEWS.md stage 6's gate: the position map, and the seven consumers of §6 taught which space
// they are in. The derived document is BUILT HERE, by hand — no plugin, no pipeline, no config
// line. What a stage would return is a list of edits, and that is what this hands `derive`.
//
// The fold is stage 5's, byte for byte: hidden_test's FOLD_2_TO_4 is what `hidden` below must
// reproduce out of the map, which is the one place the two stages have to agree.

@(private = "file")
SIX :: "aaa\nbbb\nccc\nddd\neee\nfff"

// Lines 2..4 folded into line 1's row and a marker put where they were: one deleted range and
// one inserted run, the smallest derivation that is not the identity.
//
//   aaa            aaa
//   bbb            bbb ...
//   ccc     ->     fff
//   ddd
//   eee
//   fff
@(private = "file")
folded :: proc(d: ^txt.Doc) -> (txt.Text, view.Derived) {
    return view.derive(&d.pt, []view.Edit{{7, 19, transmute([]u8)string(" ...")}})
}

@(private = "file")
mk_doc :: proc(s: string) -> txt.Doc {
    d: txt.Doc
    txt.doc_init(&d)
    txt.doc_set_text(&d, s)
    return d
}

@(private = "file")
line :: proc(t: ^txt.Text, n: int) -> string {
    return string(txt.text_line(t, n, context.temp_allocator))
}

// --- the derived document ---

@(test)
a_derived_document_is_the_edits_applied :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, _ := folded(&d)

    testing.expect_value(t, txt.text_line_count(&dt), 3)
    testing.expect_value(t, line(&dt, 0), "aaa")
    testing.expect_value(t, line(&dt, 1), "bbb ...")
    testing.expect_value(t, line(&dt, 2), "fff")
    testing.expect(t, txt.text_check(&dt), "a derived document holds every invariant a Text has")
}

// Unchanged text is the ORIGINAL's bytes, not a copy of them: only the inserted run needs a
// block of its own, which is what makes a fold cost four bytes and not a document.
@(test)
unchanged_text_points_into_the_original :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, _ := folded(&d)

    ins := len(d.pt.blocks) // the one block derive added
    carried := 0
    for p in dt.pieces {
        if p.block != ins {
            carried += 1
            testing.expect(t, raw_data(dt.blocks[p.block]) == raw_data(d.pt.blocks[p.block]),
                           "a carried piece names the original's own block")
        }
    }
    testing.expect_value(t, carried, 2) // before the fold and after it
}

// --- the two lookups ---

@(test)
a_derived_offset_answers_its_original :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, dv := folded(&d)

    o, ok := view.src_off(&dv, 5) // the second 'b', before the fold
    testing.expect(t, ok)
    testing.expect_value(t, o, 5)

    o, ok = view.src_off(&dv, txt.text_line_start(&dt, 2)) // 'f', after it
    testing.expect(t, ok)
    testing.expect_value(t, o, 20)
}

// §6: inserted text is not enterable. The marker has no byte of its own, so it answers the one
// the original resumes at — which is the fold's high edge, where a rune typed joins the text
// AFTER the run (§7).
@(test)
inserted_text_answers_the_byte_beside_it :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    _, dv := folded(&d)

    o, ok := view.src_off(&dv, 9) // mid-marker
    testing.expect(t, !ok, "no cell of a marker stands for a byte of the document")
    testing.expect_value(t, o, 19)
}

@(test)
an_original_offset_answers_its_cell :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    _, dv := folded(&d)

    o, ok := view.view_off(&dv, 21) // the second 'f'
    testing.expect(t, ok)
    testing.expect_value(t, o, 13)

    o, ok = view.view_off(&dv, 12) // 'ddd', inside the fold
    testing.expect(t, !ok, "a byte no cell stands for is not on screen")
    testing.expect_value(t, o, 7) // where the cut was made
}

// The map reproduces the list stage 5 was handed by hand. Deletions only: §6 rules inserted
// text unenterable, so motion never has to be told it is there.
@(test)
the_map_exports_the_hidden_list :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    _, dv := folded(&d)

    h := view.hidden(&dv)
    testing.expect_value(t, len(h), 1)
    testing.expect_value(t, h[0], txt.Range{{1, 3}, {4, 3}})

    txt.doc_reset_cursor(&d, {1, 0})
    txt.doc_move(&d, .Down, hidden = h)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{5, 0})
}

// --- the consumers ---

@(private = "file")
NUMBERED :: desc.Descriptor {
    render    = .Text,
    numbers   = .Absolute,
    selection = .Char,
    tab_width = 4,
}

@(private = "file")
draw_folded :: proc(
    t: ^testing.T,
    dt: ^txt.Text,
    dv: ^view.Derived,
    v := view.View{},
    cols := 12,
    rows := 3,
) -> string {
    dp := desc.new_from(NUMBERED)
    defer desc.release(dp)
    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, cols, rows))
    defer gfx.grid_destroy(&g)
    view.draw(&g, gfx.DEFAULT_THEME, dt, dp, v, 0, 0, cols, rows, nil, true, dv)
    return gfx.grid_snapshot(&g)
}

// The gate's first and third arms at once: the derived document draws, and the gutter numbers
// step 1, 2, 6 — the numbers are the ORIGINAL's, so the fold shows as a gap in them.
@(test)
a_folded_document_draws_with_a_gap_in_its_numbers :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, dv := folded(&d)

    snap := draw_folded(t, &dt, &dv)
    defer delete(snap)
    testing.expect_value(t, snap, `1 aaa
2 bbb ...
6 fff`)
}

// A line a stage inserted whole stands for no line of the original, so it is numbered by none.
@(test)
an_inserted_line_has_no_number :: proc(t: ^testing.T) {
    d := mk_doc("aaa\nbbb")
    defer txt.doc_destroy(&d)
    dt, dv := view.derive(&d.pt, []view.Edit{{4, 4, transmute([]u8)string("xxx\n")}})

    snap := draw_folded(t, &dt, &dv)
    defer delete(snap)
    testing.expect_value(t, snap, `1 aaa
  xxx
2 bbb`)
}

// The gate's second arm. A click answers a byte of the document being EDITED, never one of the
// document on screen: everything downstream of the mouse — point, selection, a bound field —
// is in original coordinates and stays there.
@(test)
the_mouse_hits_the_original_byte :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, dv := folded(&d)

    p, _, ok := view.locate(&dt, desc_of(t), {}, 0, 0, 12, 3, 3, 2, &dv)
    testing.expect(t, ok)
    testing.expect_value(t, p, txt.Pos{5, 1}) // row 2 cell 1 is 'fff', line 5 of the original

    p, _, ok = view.locate(&dt, desc_of(t), {}, 0, 0, 12, 3, 8, 1, &dv)
    testing.expect(t, ok)
    testing.expect_value(t, p, txt.Pos{4, 3}) // the marker: the fold's high edge, not a byte of it
}

@(private = "file")
desc_of :: proc(t: ^testing.T) -> ^desc.Descriptor {
    dp := desc.new_from(NUMBERED)
    testing.cleanup(t, proc(raw: rawptr) {desc.release(cast(^desc.Descriptor)raw)}, dp)
    return dp
}

// The gate's fourth arm. The selection is one range of the original; what paints is the part of
// it a cell stands for, so it comes out in two pieces with the marker dark between them.
@(test)
a_selection_across_a_fold_paints_in_two_pieces :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, dv := folded(&d)

    v := view.View{point = {anchor = {1, 1}, head = {5, 2}}}
    dp := desc.new_from(NUMBERED)
    defer desc.release(dp)
    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 12, 3))
    defer gfx.grid_destroy(&g)
    view.draw(&g, gfx.DEFAULT_THEME, &dt, dp, v, 0, 0, 12, 3, nil, true, &dv)

    testing.expect_value(t, marked(&g, 0), "")   // above the selection
    testing.expect_value(t, marked(&g, 1), "bb") // from its start to the fold, and no further
    testing.expect_value(t, marked(&g, 2), "ff") // and on again after it
}

// The runes of one row that draw in reverse video, which is the caret and the selection both.
@(private = "file")
marked :: proc(g: ^gfx.Grid, y: int) -> string {
    out := make([dynamic]u8, 0, g.cols, context.temp_allocator)
    for x in 0 ..< g.cols {
        if c := gfx.grid_at(g, x, y); c != nil && .Reverse in c.attrs {
            append(&out, u8(c.r))
        }
    }
    return string(out[:])
}

// --- the edges ---

// An edit at byte 0: no run precedes the marker, and both lookups still answer — the deleted
// prefix answers cell 0, the marker answers the byte the original resumes at.
@(test)
a_deleted_prefix_still_answers :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, dv := view.derive(&d.pt, []view.Edit{{0, 4, transmute([]u8)string(">")}})

    testing.expect_value(t, line(&dt, 0), ">bbb")
    o, ok := view.src_off(&dv, 0)
    testing.expect(t, !ok)
    testing.expect_value(t, o, 4)
    o, ok = view.view_off(&dv, 2)
    testing.expect(t, !ok)
    testing.expect_value(t, o, 0)
    h := view.hidden(&dv)
    testing.expect_value(t, len(h), 1)
    testing.expect_value(t, h[0], txt.Range{{0, 0}, {1, 0}})
}

// An INLINE substitution (§6's prettify case): real text on both sides of the marker in one
// row, the lookups agreeing at the seam, and a selection over it painting around the marker
// without leaving its own row.
@(test)
an_inline_substitution_maps_within_the_line :: proc(t: ^testing.T) {
    d := mk_doc("abcdef")
    defer txt.doc_destroy(&d)
    dt, dv := view.derive(&d.pt, []view.Edit{{2, 4, transmute([]u8)string("__")}})
    testing.expect_value(t, line(&dt, 0), "ab__ef")

    o, ok := view.src_off(&dv, 4) // 'e', the first cell past the marker
    testing.expect(t, ok)
    testing.expect_value(t, o, 4)
    o, ok = view.view_off(&dv, 2) // 'c', under it
    testing.expect(t, !ok)
    testing.expect_value(t, o, 2)

    v := view.View{point = {anchor = {0, 1}, head = {0, 5}}} // b..e of the ORIGINAL
    dp := desc.new_from(NUMBERED)
    defer desc.release(dp)
    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 12, 1))
    defer gfx.grid_destroy(&g)
    view.draw(&g, gfx.DEFAULT_THEME, &dt, dp, v, 0, 0, 12, 1, nil, true, &dv)
    testing.expect_value(t, marked(&g, 0), "be")
}

// What view_run's refusal lets through, `derive` clamps: a backwards or overlapping pair still
// yields a Text, with the straggler pulled to where the previous edit ended.
@(test)
overlapping_edits_cannot_corrupt_the_derivation :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, dv := view.derive(&d.pt, []view.Edit{{4, 8, transmute([]u8)string("x")},
                                             {6, 2, transmute([]u8)string("y")}})

    testing.expect(t, txt.text_check(&dt), "an overlapping pair broke a Text invariant")
    testing.expect_value(t, line(&dt, 1), "xyccc")
    h := view.hidden(&dv)
    testing.expect_value(t, len(h), 1)
    testing.expect_value(t, h[0], txt.Range{{1, 0}, {2, 0}})
}

// --- two stages, one map (stage 7) ---

// A pipeline leaves one map per stage, each back to the stage before it, and every consumer of
// §6 holds ONE. `compose` is that fold, and these are the three cases it has to get right: a
// deletion under a deletion, an insertion over a deletion, and a deletion that falls inside
// text the stage below it inserted.

// The fold above, then a second stage hanging a box off the end of the row it left. The box's
// bytes belong to neither the first stage nor the file.
@(private = "file")
two_stages :: proc(d: ^txt.Doc) -> (txt.Text, view.Derived) {
    dt, one := folded(d)
    // "aaa\nbbb ...\nfff" — the box goes after `bbb ...`, which is offset 11.
    dt2, two := view.derive(&dt, []view.Edit{{11, 11, transmute([]u8)string("\n[box]")}})
    return dt2, view.compose(two, one)
}

@(test)
two_stages_compose_into_one_map :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, dv := two_stages(&d)

    testing.expect_value(t, txt.text_line_count(&dt), 4)
    testing.expect_value(t, line(&dt, 1), "bbb ...")
    testing.expect_value(t, line(&dt, 2), "[box]")
    testing.expect_value(t, line(&dt, 3), "fff")
    testing.expect(t, txt.text_check(&dt), "a twice-derived document is still a Text")

    // The map is back to the ORIGINAL and not to the stage between: `fff` is at 20 in SIX, and
    // it is the fourth line of what is drawn.
    off, on := view.src_off(&dv, txt.text_line_start(&dt, 3))
    testing.expect(t, on, "the last line lost its original bytes")
    testing.expect_value(t, off, 20)
    testing.expect_value(t, view.src_line(&dv, &dt, 3), 5)
}

// Both stages' insertions stay insertions, and each answers where the ORIGINAL resumes — the
// first stage's marker included, whose resume point had to be mapped through nothing at all.
@(test)
composing_keeps_every_inserted_run_inserted :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, dv := two_stages(&d)

    marker, in_doc := view.src_off(&dv, 7) // the ` ...` the fold put in
    testing.expect(t, !in_doc, "a fold marker claimed to be in the document")
    testing.expect_value(t, marker, 19) // where `fff` starts in SIX

    box, boxed := view.src_off(&dv, txt.text_line_start(&dt, 2))
    testing.expect(t, !boxed, "a popup box claimed to be in the document")
    testing.expect_value(t, box, 19)
    testing.expect_value(t, view.src_line(&dv, &dt, 2), -1) // every byte of it was inserted
}

// The composed map is what motion is handed, so the two stages' deletions have to come back as
// ONE run of the original — not as the second stage's view of the first stage's document.
@(test)
composing_exports_one_hidden_list :: proc(t: ^testing.T) {
    d := mk_doc(SIX)
    defer txt.doc_destroy(&d)
    dt, one := folded(&d)
    // A second fold, over `fff` — line 2 of what the first stage produced.
    dt2, two := view.derive(&dt, []view.Edit{{12, 15, nil}})
    dv := view.compose(two, one)
    _ = dt2

    runs := view.hidden(&dv)
    testing.expect_value(t, len(runs), 2)
    testing.expect_value(t, runs[0], txt.Range{{1, 3}, {4, 3}}) // what the first stage cut
    testing.expect_value(t, runs[1], txt.Range{{5, 0}, {5, 3}}) // and what the second did
}

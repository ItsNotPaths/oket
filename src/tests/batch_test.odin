package tests

import "core:strings"
import "core:testing"
import "core:time"
import "../txt"

// A TRANSACTION IS ONE PASS (VIEWS.md §11, stage 2). A splice per caret is O(N * pieces) and
// N log entries against a cap a browser's links do not survive the loss of. cursor.split_lines
// makes a thousand carets in one press, which is what turns both into a real cost.

@(private = "file")
CARETS :: 1000

// N inserts, evenly spread and never touching, so doc_apply fuses none of them.
@(private = "file")
spread :: proc(n, at, stride: int, text: string) -> []txt.Edit {
    out := make([]txt.Edit, n, context.temp_allocator)
    for i in 0 ..< n {
        off := at + i * stride
        out[i] = txt.Edit{lo = off, hi = off, text = text}
    }
    return out
}

// THE GATE, MEASURED. `pt.touched` counts the pieces one transaction looked at, and the claim is
// that it tracks pieces + carets. A tail walk per caret is two million visits on this fixture
// rather than three thousand, so the budget fails it outright.
@(test)
a_thousand_caret_edit_is_linear_in_pieces :: proc(t: ^testing.T) {
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, strings.repeat(".", 8 * CARETS, context.temp_allocator))

    // Splinter the table first: a rebuild over one piece would measure nothing.
    txt.doc_apply(&d, spread(CARETS, 0, 8, "a"))
    pieces := len(d.pt.pieces)
    testing.expectf(t, pieces > CARETS, "the fixture left %d pieces; it never splintered", pieces)

    txt.doc_apply(&d, spread(CARETS, 4, 9, "b"))

    budget := 2 * (pieces + CARETS)
    testing.expectf(t, d.pt.touched <= budget, "%d piece visits for %d carets over %d pieces",
                    d.pt.touched, CARETS, pieces)
    testing.expect_value(t, txt.doc_len(&d), 10 * CARETS)
}

// THE SECOND GATE, AND IT IS A CLOCK because there is nothing to count: edit_cursors' cost is
// map probes, and a counter on the Doc that only this test reads would be a field earning
// nothing. What makes a clock honest here is the distance — a rescan per caret is ~16 s on this
// fixture in a test build before the sanitizer multiplies it, the map ~25 ms alone and ~2 s
// under a contended ASan run, so the budget sits clear of both ends. The 60 Hz budgets
// elsewhere have no such room.
//
// `:find` is what makes the fixture real: one caret per match over a large buffer, then a rune.
@(test)
typing_over_sixty_thousand_carets_is_not_quadratic :: proc(t: ^testing.T) {
    SPANS :: 60_000
    BUDGET :: 8 * time.Second

    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, strings.repeat("ab\n", SPANS, context.temp_allocator))

    spans := make([][2]txt.Pos, SPANS, context.temp_allocator)
    for i in 0 ..< SPANS {
        spans[i] = {{i, 0}, {i, 1}} // one selection per line, none of them touching
    }
    txt.doc_set_spans(&d, spans)
    testing.expect_value(t, len(d.cursors), SPANS)

    start := time.tick_now()
    testing.expect(t, txt.doc_insert_rune(&d, 'X'))
    took := time.tick_since(start)

    testing.expectf(t, took < BUDGET, "one rune over %d carets took %v", SPANS, took)
    testing.expect_value(t, len(d.cursors), SPANS)
}

// A COMMIT IS ATOMIC IN THE LOG. DOC_CHANGE_MAX bounds what may accumulate BETWEEN commits; a
// batch past it still lands whole, because half a transaction leaves a reader carrying its
// spans through some of the splices under them and not the rest, and nothing afterwards says so.
@(test)
a_batch_bigger_than_the_log_still_lands_whole :: proc(t: ^testing.T) {
    ROWS :: 300 // past DOC_CHANGE_MAX

    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, strings.repeat(".", 4 * ROWS, context.temp_allocator))
    txt.doc_changes_ack(&d, .Fields) // the load is a change nobody was here for

    txt.doc_apply(&d, spread(ROWS, 0, 4, "x"))

    changes, lost := txt.doc_changes_since(&d, .Fields)
    testing.expect(t, !lost, "a 300-caret edit dropped its own change log")
    testing.expect_value(t, len(changes), ROWS)

    // And the cap still bites between commits, which is the half that keeps the log bounded.
    txt.doc_apply(&d, {txt.Edit{lo = 0, hi = 0, text = "y"}})
    _, lost = txt.doc_changes_since(&d, .Fields)
    testing.expect(t, lost, "the log grew past its cap and stayed there")
}

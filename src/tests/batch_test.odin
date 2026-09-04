package tests

import "core:strings"
import "core:testing"
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

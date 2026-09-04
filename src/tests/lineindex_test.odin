package tests

import "core:strings"
import "core:testing"
import "../txt"

// The line index is segments over an append-only pool with a per-segment delta, so an edit
// re-bases one add per SEGMENT rather than one per line (piecetable.odin, after RAD Debugger's
// TXT_LineMapRangeNode). That is a representation swap under the hottest code in the editor,
// so it is checked against the obvious slow answer rather than against itself.

// Line starts computed the dumb way: scan the bytes.
@(private = "file")
starts_of :: proc(text: string, alloc := context.temp_allocator) -> []int {
    out := make([dynamic]int, 0, 16, alloc)
    append(&out, 0)
    for c, i in transmute([]u8)text {
        if c == '\n' {
            append(&out, i + 1)
        }
    }
    return out[:]
}

@(private = "file")
expect_index :: proc(t: ^testing.T, d: ^txt.Doc, want_text: string, step: int) -> bool {
    got := txt.doc_string(d, context.temp_allocator)
    if !testing.expectf(t, got == want_text, "step %d: text diverged\n got %q\nwant %q",
                        step, got, want_text) {
        return false
    }
    want := starts_of(want_text)
    if !testing.expectf(t, txt.doc_line_count(d) == len(want),
                        "step %d: %d lines, want %d", step, txt.doc_line_count(d), len(want)) {
        return false
    }
    for start, line in want {
        if !testing.expectf(t, txt.doc_off(d, txt.Pos{line, 0}) == start,
                            "step %d: line %d starts at %d, want %d", step, line,
                            txt.doc_off(d, txt.Pos{line, 0}), start) {
            return false
        }
    }
    // And the reverse map, which is the binary search over segments rather than over an array.
    for start, line in want {
        if !testing.expectf(t, txt.doc_pos(d, start).line == line,
                            "step %d: offset %d maps to line %d, want %d", step, start,
                            txt.doc_pos(d, start).line, line) {
            return false
        }
    }
    return true
}

// Random splices against a plain string. Newlines are over-represented on purpose: they are
// what makes a segment, and a segment is what the whole change is about.
@(test)
line_index_matches_a_plain_scan :: proc(t: ^testing.T) {
    alphabet := "aaa\n\nbb\ncc"
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)

    txt.doc_set_text(&d, "one\ntwo\nthree\nfour\n")
    want := strings.builder_make(context.allocator)
    defer strings.builder_destroy(&want)
    // Seeded from the Doc, not from the literal: doc_set_text normalizes, and a trailing
    // newline is edit.Buffer's business (final_newline) rather than the document's.
    strings.write_string(&want, txt.doc_string(&d, context.temp_allocator))

    seed: u64 = RNG_SEED

    for step in 0 ..< 400 {
        cur := strings.to_string(want)
        lo := rng_next(&seed, len(cur) + 1)
        hi := lo + rng_next(&seed, min(8, len(cur) - lo + 1))
        ins := strings.builder_make(context.temp_allocator)
        for _ in 0 ..< rng_next(&seed, 6) {
            strings.write_byte(&ins, alphabet[rng_next(&seed, len(alphabet))])
        }
        text := strings.to_string(ins)

        txt.doc_apply(&d, {txt.Edit{lo = lo, hi = hi, text = text}})

        next := strings.concatenate({cur[:lo], text, cur[hi:]}, context.temp_allocator)
        strings.builder_reset(&want)
        strings.write_string(&want, next)

        if !expect_index(t, &d, next, step) {
            return
        }
    }
}

// Deliberately past PT_COMPACT_SEGS, because flattening the segments back into one is the half
// of the design that only runs after a few thousand edits and would otherwise never be hit.
// The text here is the Doc's own, so what is being checked is the index against a fresh scan
// of the bytes — which is the assertion that matters.
@(test)
line_index_survives_compaction :: proc(t: ^testing.T) {
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "start\n")

    // Newlines at the FRONT: every one is a fresh segment and re-bases everything after it,
    // which is exactly the shape the old flat array was O(document) on.
    for i in 0 ..< 2500 {
        txt.doc_apply(&d, {txt.Edit{lo = 0, hi = 0, text = "x\n"}})
        if i % 500 == 0 || i == 2499 {
            if !expect_index(t, &d, txt.doc_string(&d, context.temp_allocator), i) {
                return
            }
        }
    }
    testing.expect_value(t, txt.doc_line_count(&d), 2501) // 2500 inserted, plus "start"
}

// The same check with a whole transaction landing at once. A batch cuts in N places, so it
// cannot use the incremental index — one splice re-bases the segments after it, and N splices
// would re-base them N times — and flattens instead. This is what says the flat answer and a
// plain scan agree.
@(test)
line_index_matches_a_plain_scan_under_a_batch :: proc(t: ^testing.T) {
    alphabet := "aaa\n\nbb\ncc"
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)

    // Long enough that a batch is genuinely several edits: they march forward and never touch,
    // so how many fit is how much document there is.
    txt.doc_set_text(&d, strings.repeat("one\ntwo\nthree\nfour\n", 40, context.temp_allocator))
    want := strings.builder_make(context.allocator)
    defer strings.builder_destroy(&want)
    strings.write_string(&want, txt.doc_string(&d, context.temp_allocator))

    seed: u64 = RNG_SEED

    for step in 0 ..< 200 {
        cur := strings.to_string(want)
        // Strictly apart and ascending, which is what doc_apply hands the piece table once it
        // has fused the overlaps a real caret set makes.
        edits := make([dynamic]txt.Edit, 0, 32, context.temp_allocator)
        at := 0
        for _ in 0 ..< rng_next(&seed, 24) + 1 {
            lo := at + rng_next(&seed, 4)
            if lo > len(cur) {
                break
            }
            hi := lo + rng_next(&seed, min(5, len(cur) - lo + 1))
            ins := strings.builder_make(context.temp_allocator)
            for _ in 0 ..< rng_next(&seed, 5) {
                strings.write_byte(&ins, alphabet[rng_next(&seed, len(alphabet))])
            }
            append(&edits, txt.Edit{lo = lo, hi = hi, text = strings.to_string(ins)})
            at = hi + 1
        }
        if len(edits) == 0 {
            continue
        }
        txt.doc_apply(&d, edits[:])

        // The same edits against a plain string, back to front, so each one's offsets stay true.
        next := cur
        for i := len(edits) - 1; i >= 0; i -= 1 {
            e := edits[i]
            next = strings.concatenate(
                {next[:e.lo], e.text, next[e.hi:]},
                context.temp_allocator,
            )
        }
        strings.builder_reset(&want)
        strings.write_string(&want, next)

        if !expect_index(t, &d, next, step) {
            return
        }
    }
}

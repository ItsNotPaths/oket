package tests

import "core:testing"
import "../gfx"
import "../store"
import "../txt"
import app "../oket"

// The span store and the token table (§5, §9), which is what keeps tree-sitter out of the
// kernel: the kernel STORES style runs and never computes them, and a name becomes a colour in
// one place that no plugin can reach past.
//
// Kernel-only, on purpose. The plugin half is syntax_test.odin, over a real grammar.

@(private = "file")
SOURCE :: "let a = 1\nlet b = 2\n"

@(private = "file")
RED :: [3]f32{1, 0, 0}

@(private = "file")
BLUE :: [3]f32{0, 0, 1}

@(private = "file")
spans_app :: proc(t: ^testing.T) -> (a: app.App, id: store.Id, ok: bool) {
    a = bare_app() or_return
    id = scratch_doc(&a, "a.txt", SOURCE)
    return a, id, true
}

@(private = "file")
publish :: proc(a: ^app.App, id: store.Id, layer: store.Layer, lo, hi: int,
                list: []store.Span) -> bool {
    return store.store_spans_publish(&a.docs, id, {layer, lo, hi, list})
}

// A publish REPLACES its range and never appends: a layer republishing one screen must not make
// the store grow with the file. What is outside the range is untouched, and a span straddling
// the edge is CLIPPED rather than dropped — else republishing a screen would delete the tail of
// a string that began above it.
@(test)
publishing_replaces_its_range :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    first := [?]store.Span{{lo = 0, hi = 3, fg = RED}, {lo = 4, hi = 14, fg = RED}}
    testing.expect(t, publish(&a, id, .Syntax, 0, 20, first[:]), "not published")
    testing.expect_value(t, len(store.store_spans(&a.docs, id, 0, 20)), 2)

    // [4, 8) only. The run at 0 is below it and stays; the run that reached to 14 keeps the
    // half above 8 and loses the half inside.
    second := [?]store.Span{{lo = 5, hi = 7, fg = BLUE}}
    testing.expect(t, publish(&a, id, .Syntax, 4, 8, second[:]), "not published")
    out := store.store_spans(&a.docs, id, 0, 20)
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], store.Span{lo = 0, hi = 3, fg = RED})
    testing.expect_value(t, out[1], store.Span{lo = 5, hi = 7, fg = BLUE})
    testing.expect_value(t, out[2], store.Span{lo = 8, hi = 14, fg = RED})
}

// The layers stack in one fixed order and the kernel folds them, so nothing merges by hand: a
// search hit outranks a keyword, and what is left of the keyword fills in around it.
@(test)
a_higher_layer_cuts_the_one_below :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    base := [?]store.Span{{lo = 0, hi = 9, fg = RED}}
    hit := [?]store.Span{{lo = 4, hi = 5, fg = BLUE}}
    testing.expect(t, publish(&a, id, .Syntax, 0, 9, base[:]))
    testing.expect(t, publish(&a, id, .Search, 4, 5, hit[:]))

    out := store.store_spans(&a.docs, id, 0, 9)
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], store.Span{lo = 0, hi = 4, fg = RED})
    testing.expect_value(t, out[1], store.Span{lo = 4, hi = 5, fg = BLUE})
    testing.expect_value(t, out[2], store.Span{lo = 5, hi = 9, fg = RED})

    // One publisher going quiet leaves the other's colours alone, which is the whole reason
    // there is a layer per publisher rather than one list.
    testing.expect(t, publish(&a, id, .Search, 0, 9, nil))
    back := store.store_spans(&a.docs, id, 0, 9)
    testing.expect_value(t, len(back), 1)
    testing.expect_value(t, back[0], store.Span{lo = 0, hi = 9, fg = RED})
}

// A publisher's list is untrusted (oket.h): reversed, out of order, overlapping and outside
// the named range must all be survived — clipped, sorted, and an overlap resolved in favour of
// whichever span starts first.
@(test)
an_untrusted_publish_is_clipped_and_flattened :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    messy := [?]store.Span{
        {lo = 8, hi = 3, fg = RED},   // reversed: dropped
        {lo = 6, hi = 20, fg = RED},  // out of order, past the range: loses to the BLUE one
        {lo = 2, hi = 7, fg = BLUE},  // starts first, so it wins the overlap whole
        {lo = 9, hi = 30, fg = RED},  // clipped to the range's edge
    }
    testing.expect(t, publish(&a, id, .Syntax, 0, 10, messy[:]), "not published")
    out := store.store_spans(&a.docs, id, 0, 20)
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0], store.Span{lo = 2, hi = 7, fg = BLUE})
    testing.expect_value(t, out[1], store.Span{lo = 9, hi = 10, fg = RED})
}

// The cap is on what SURVIVES, not on what arrives, so a layer sitting at it can still
// republish itself — and a refusal leaves the store exactly as it was rather than half written.
@(test)
a_layer_that_would_outgrow_the_cap_is_refused :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    full := make([]store.Span, store.SPAN_MAX, context.temp_allocator)
    for &sp, i in full {
        sp = {lo = i * 2, hi = i * 2 + 1, fg = RED}
    }
    testing.expect(t, publish(&a, id, .Syntax, 0, max(int), full), "the cap refused a full set")
    testing.expect_value(t, len(store.store_spans(&a.docs, id, 0, max(int))), store.SPAN_MAX)

    // The same set again: it replaces rather than adding, so the cap must not stand in its way.
    testing.expect(t, publish(&a, id, .Syntax, 0, max(int), full), "a republish was refused")

    over := [?]store.Span{{lo = 1, hi = 2, fg = BLUE}}
    testing.expect(t, !publish(&a, id, .Syntax, 1, 2, over[:]), "one span past the cap went in")
    kept := store.store_spans(&a.docs, id, 0, 4)
    testing.expect_value(t, kept[0].fg, RED) // refused, and nothing of it landed
}

// A run is DOCUMENT BYTES, so one of them crosses a line end. The renderer is where it is split,
// and only for the lines the viewport is showing.
@(test)
a_run_is_bytes_and_the_renderer_splits_it_by_line :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_app(&a)
    snap := store.store_snapshot(&a.docs, id)
    defer txt.snapshot_release(snap)

    // From "a = 1" on line 0 through "let" on line 1: one publish, two drawn rows.
    across := [?]store.Span{{lo = 4, hi = 13, fg = RED, attrs = 1}}
    testing.expect(t, publish(&a, id, .Syntax, 0, 20, across[:]))

    out := app.doc_styles(&a, id, &snap.text, 0, 4)
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0].line, 0)
    testing.expect_value(t, out[0].lo, 4) // to the end of "let a = 1", the newline excluded
    testing.expect_value(t, out[0].hi, 9)
    testing.expect_value(t, out[1].line, 1)
    testing.expect_value(t, out[1].lo, 0)
    testing.expect_value(t, out[1].hi, 3)
    testing.expect_value(t, out[0].attrs, gfx.Attrs{.Bold})

    // And only what is on screen costs anything: the store holds both, one row asks for one.
    one := app.doc_styles(&a, id, &snap.text, 1, 1)
    testing.expect_value(t, len(one), 1)
    testing.expect_value(t, one[0].line, 1)
}

// A name is the vocabulary, not an id: whoever asks second gets what the first one got, which is
// what lets a parser and a linter publish into one theme without knowing about each other.
@(test)
one_name_is_one_token :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)
    defer app.tokens_destroy(&a)

    kw := app.token_intern(&a, "keyword")
    testing.expect_value(t, app.token_intern(&a, "keyword"), kw)
    testing.expect(t, kw >= 5, "an interned name must not land on the base five")
    // The base five are seeded, so a plugin may name one and gets the id the ABI documents.
    testing.expect_value(t, app.token_intern(&a, "accent"), u16(gfx.Token.Accent))
    testing.expect_value(t, app.token_color(&a, u16(gfx.Token.Accent)), a.theme[.Accent])

    // Only the base before the first dot has to be known for a name to have a colour, which is
    // what lets a palette of twenty keys colour a query of three hundred capture names.
    testing.expect_value(
        t,
        app.token_color(&a, app.token_intern(&a, "function.builtin")),
        app.token_color(&a, app.token_intern(&a, "function")),
    )
    // And a vocabulary oket has never heard of still draws.
    testing.expect_value(t, app.token_color(&a, app.token_intern(&a, "wat")), a.theme[.Fg])
}

// Spans ride a transaction, so the runs and the bytes they cover land at ONE generation: a
// publish against a document that has moved is dropped whole, exactly like an edit.
@(test)
a_stale_span_publish_is_dropped_with_its_transaction :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    gen, _ := store.store_gen(&a.docs, id)
    list := [?]store.Span{{lo = 0, hi = 3, fg = RED}}
    // Both were written against `gen`, in one frame. The edit lands and moves it, so the
    // publish behind it is measured against bytes that are gone and goes whole.
    store.store_submit(&a.docs, id, gen, {{0, 0, "x", 0}})
    store.store_submit(&a.docs, id, gen, nil, nil,
                       store.Spans{layer = .Syntax, lo = 0, hi = 9, list = list[:]})
    store.store_drain(&a.docs)
    testing.expect_value(t, len(store.store_spans(&a.docs, id, 0, 20)), 0)

    moved, _ := store.store_gen(&a.docs, id)
    store.store_submit(&a.docs, id, moved, nil, nil,
                       store.Spans{layer = .Syntax, lo = 0, hi = 9, list = list[:]})
    store.store_drain(&a.docs)
    testing.expect_value(t, len(store.store_spans(&a.docs, id, 0, 20)), 1)
}

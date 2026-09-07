package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "../desc"
import "../gfx"
import "../input"
import "../store"
import "../txt"
import "../view"
import app "../oket"

// The span store and the token table (§5, §9, VIEWS §8), which is what keeps tree-sitter out of
// the kernel: the kernel STORES style runs and never computes them, and a name becomes a colour
// in one place that no plugin can reach past.
//
// THE PRODUCER IS THE LAYER. A publisher owns a bucket under its own name, the z-order is a
// config line, and a run says which CHANNELS it sets — so two publishers at one byte share the
// cell instead of the top one deleting the other.
//
// Kernel-only, on purpose. The plugin half is syntax_test.odin, over a real grammar.

@(private = "file")
SOURCE :: "let a = 1\nlet b = 2\n"

@(private = "file")
RED :: gfx.COLOR_LIT | 0xFF0000

@(private = "file")
BLUE :: gfx.COLOR_LIT | 0x0000FF

@(private = "file")
FG :: desc.Chans{.Fg}

@(private = "file")
spans_app :: proc(t: ^testing.T) -> (a: app.App, id: store.Id, ok: bool) {
    a = bare_app() or_return
    id = scratch_doc(&a, "a.txt", SOURCE)
    return a, id, true
}

@(private = "file")
publish :: proc(a: ^app.App, id: store.Id, who: string, lo, hi: int,
                list: []store.Span) -> bool {
    return store.store_spans_publish(&a.docs, id, {app.producer_intern(a, who), lo, hi, list})
}

// What the renderer would read: every publisher, in the order this document ranks them.
@(private = "file")
merged :: proc(a: ^app.App, id: store.Id, lo, hi: int) -> []store.Span {
    return store.store_spans(&a.docs, id, lo, hi, app.spans_order(a, id))
}

@(private = "file")
fg :: proc(lo, hi: int, color: u32) -> store.Span {
    return {lo = lo, hi = hi, fg = color, set = FG}
}

// A publish REPLACES its range and never appends: a publisher republishing one screen must not
// make the store grow with the file. What is outside the range is untouched, and a span
// straddling the edge is CLIPPED rather than dropped — else republishing a screen would delete
// the tail of a string that began above it.
@(test)
publishing_replaces_its_range :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)

    first := [?]store.Span{fg(0, 3, RED), fg(4, 14, RED)}
    testing.expect(t, publish(&a, id, "syntax", 0, 20, first[:]), "not published")
    testing.expect_value(t, len(merged(&a, id, 0, 20)), 2)

    // [4, 8) only. The run at 0 is below it and stays; the run that reached to 14 keeps the
    // half above 8 and loses the half inside.
    second := [?]store.Span{fg(5, 7, BLUE)}
    testing.expect(t, publish(&a, id, "syntax", 4, 8, second[:]), "not published")
    out := merged(&a, id, 0, 20)
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], fg(0, 3, RED))
    testing.expect_value(t, out[1], fg(5, 7, BLUE))
    testing.expect_value(t, out[2], fg(8, 14, RED))
}

// THE GATE. Two publishers over one range delete nothing of each other's: a bucket is per
// producer, so the loser of a colour still owns its own runs and gets them back the moment the
// winner goes quiet.
@(test)
two_publishers_over_one_range_keep_their_own_runs :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)

    base := [?]store.Span{fg(0, 9, RED)}
    hit := [?]store.Span{fg(4, 5, BLUE)}
    testing.expect(t, publish(&a, id, "aaa", 0, 9, base[:]))
    testing.expect(t, publish(&a, id, "zzz", 4, 5, hit[:])) // above it: nothing was named

    out := merged(&a, id, 0, 9)
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], fg(0, 4, RED))
    testing.expect_value(t, out[1], fg(4, 5, BLUE))
    testing.expect_value(t, out[2], fg(5, 9, RED))

    // One publisher going quiet leaves the other's colours whole, which is the whole reason
    // there is a bucket per publisher rather than one list.
    testing.expect(t, publish(&a, id, "zzz", 0, 9, nil))
    back := merged(&a, id, 0, 9)
    testing.expect_value(t, len(back), 1)
    testing.expect_value(t, back[0], fg(0, 9, RED))
}

// THE GATE. An underline over a colour draws as BOTH. The publisher on top set attributes and
// said nothing about colour, so the colour under it survives — which is the sharing that costs
// no grouping syntax and that nobody had to predict the pairing for.
@(test)
an_underline_over_a_colour_draws_as_both :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)

    color := [?]store.Span{fg(0, 9, RED)}
    under := transmute(u8)gfx.Attrs{.Underline}
    mark := [?]store.Span{{lo = 4, hi = 7, attrs = under, set = {.Attrs}}}
    testing.expect(t, publish(&a, id, "aaa", 0, 9, color[:]))
    testing.expect(t, publish(&a, id, "zzz", 4, 7, mark[:]))

    out := merged(&a, id, 0, 9)
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[1].lo, 4)
    testing.expect_value(t, out[1].hi, 7)
    testing.expect_value(t, out[1].fg, RED) // the colour under it, kept
    testing.expect_value(t, out[1].attrs, under)
    testing.expect_value(t, out[1].set, desc.Chans{.Fg, .Attrs})
    // And the theme fills what nobody set, at the renderer and not in the store: a store that
    // filled a colour in would have made every publisher opaque again.
    snap := store.store_snapshot(&a.docs, id)
    defer txt.snapshot_release(snap)
    drawn := app.doc_styles(&a, id, nil, &snap.text, nil, 0, 4)
    testing.expect_value(t, drawn[1].fg, RED)
    testing.expect_value(t, drawn[1].bg, u32(gfx.Token.Bg))
    testing.expect_value(t, drawn[1].attrs, gfx.Attrs{.Underline})
    testing.expect_value(t, drawn[0].attrs, gfx.Attrs{}) // outside the mark, and not underlined
}

// THE GATE. A search hit draws a BACKGROUND: a token names whichever channel the run claims, so
// the same vocabulary that colours a keyword highlights a hit — and the foreground the parser
// published goes on showing through it.
@(test)
a_search_hit_draws_a_background :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)

    color := [?]store.Span{fg(0, 9, RED)}
    hit := [?]store.Span{{lo = 4, hi = 7, bg = BLUE, set = {.Bg}}}
    testing.expect(t, publish(&a, id, "aaa", 0, 9, color[:]))
    testing.expect(t, publish(&a, id, "zzz", 4, 7, hit[:]))

    out := merged(&a, id, 0, 9)
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[1], store.Span{lo = 4, hi = 7, fg = RED, bg = BLUE,
                                               set = {.Fg, .Bg}})
    // Outside the hit the background is nobody's, and the renderer reads the theme's.
    testing.expect_value(t, out[0].set, FG)
}

// The z-order is a CONFIG LINE, and the file is the answer: `spans` under a kind's section
// names its publishers lowest first. Rewriting the line inverts what draws over what with no
// plugin rebuilt and nothing in a descriptor touched.
@(test)
a_config_line_is_the_z_order :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-spans-order")
    if !made {
        return
    }
    defer os.remove_all(dir)
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_spans_app(&a)
    app.home_set(&a.home, dir)
    defer app.home_destroy(&a.home)
    id := kinded_doc(&a, app.KIND_HOME)

    path, _ := filepath.join({dir, app.CONFIG_NAME}, context.temp_allocator)
    body := "[home]\nspans = zzz, aaa\n"
    testing.expect_value(t, os.write_entire_file(path, transmute([]u8)body), nil)
    app.config_load(&a)

    under := [?]store.Span{fg(0, 9, RED)}
    over := [?]store.Span{fg(4, 5, BLUE)}
    testing.expect(t, publish(&a, id, "zzz", 0, 9, under[:]))
    testing.expect(t, publish(&a, id, "aaa", 4, 5, over[:]))

    // Name order would have put `aaa` under `zzz`; the file says otherwise and the file wins.
    out := merged(&a, id, 0, 9)
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[1], fg(4, 5, BLUE))

    // A publisher the line does not name draws ON TOP of the ones it does: a file ranks what
    // its author has an opinion about, and one installed tomorrow must not come up invisible.
    newcomer := [?]store.Span{{lo = 0, hi = 9, bg = BLUE, set = {.Bg}}}
    testing.expect(t, publish(&a, id, "mmm", 0, 9, newcomer[:]))
    top := merged(&a, id, 0, 9)
    testing.expect_value(t, top[0].bg, BLUE)
}

// A publisher's runs go when it does, and nobody else's move: the bucket is the unit, so an
// unload is a clear rather than a merge (plug_unload).
@(test)
forgetting_a_publisher_leaves_the_rest :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)

    mine := [?]store.Span{fg(0, 4, RED)}
    theirs := [?]store.Span{fg(5, 9, BLUE)}
    testing.expect(t, publish(&a, id, "aaa", 0, 4, mine[:]))
    testing.expect(t, publish(&a, id, "zzz", 5, 9, theirs[:]))

    // Disjoint, with a hole at [4, 5) that neither paints: the merge jumps it.
    both := merged(&a, id, 0, 9)
    testing.expect_value(t, len(both), 2)
    testing.expect_value(t, both[0], fg(0, 4, RED))
    testing.expect_value(t, both[1], fg(5, 9, BLUE))

    store.store_spans_forget(&a.docs, app.producer_intern(&a, "aaa"))
    out := merged(&a, id, 0, 9)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], fg(5, 9, BLUE))
}

// The sweep cuts at every edge either producer has, and an edge that changes nothing must not
// reach the renderer: adjacent runs drawing the same thing come back as one run.
@(test)
runs_saying_the_same_thing_are_one_run :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)

    base := [?]store.Span{fg(0, 9, RED)}
    same := [?]store.Span{fg(4, 5, RED)} // the claim the run below already makes
    testing.expect(t, publish(&a, id, "aaa", 0, 9, base[:]))
    testing.expect(t, publish(&a, id, "zzz", 4, 5, same[:]))

    out := merged(&a, id, 0, 9)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], fg(0, 9, RED))

    // A run that sets no channel says nothing, and the store does not keep it.
    mute := [?]store.Span{{lo = 0, hi = 9}}
    testing.expect(t, publish(&a, id, "mmm", 0, 9, mute[:]))
    testing.expect_value(t, len(merged(&a, id, 0, 9)), 1)
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
    defer close_spans_app(&a)

    messy := [?]store.Span{
        fg(8, 3, RED),   // reversed: dropped
        fg(6, 20, RED),  // out of order, past the range: loses to the BLUE one
        fg(2, 7, BLUE),  // starts first, so it wins the overlap whole
        fg(9, 30, RED),  // clipped to the range's edge
    }
    testing.expect(t, publish(&a, id, "syntax", 0, 10, messy[:]), "not published")
    out := merged(&a, id, 0, 20)
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0], fg(2, 7, BLUE))
    testing.expect_value(t, out[1], fg(9, 10, RED))
}

// The cap is per publisher and on what SURVIVES, not on what arrives, so one sitting at it can
// still republish itself — and a refusal leaves the store exactly as it was rather than half
// written. Per publisher, so one of them cannot starve another out of it.
@(test)
a_publisher_that_would_outgrow_the_cap_is_refused :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)

    full := make([]store.Span, store.SPAN_MAX, context.temp_allocator)
    for &sp, i in full {
        sp = fg(i * 2, i * 2 + 1, RED)
    }
    testing.expect(t, publish(&a, id, "syntax", 0, max(int), full), "the cap refused a full set")
    testing.expect_value(t, len(merged(&a, id, 0, max(int))), store.SPAN_MAX)

    // The same set again: it replaces rather than adding, so the cap must not stand in its way.
    testing.expect(t, publish(&a, id, "syntax", 0, max(int), full), "a republish was refused")

    over := [?]store.Span{fg(1, 2, BLUE)}
    testing.expect(t, !publish(&a, id, "syntax", 1, 2, over[:]), "one span past the cap went in")
    kept := merged(&a, id, 0, 4)
    testing.expect_value(t, kept[0].fg, RED) // refused, and nothing of it landed

    // Another publisher is not held to what this one has spent.
    other := [?]store.Span{fg(1, 2, BLUE)}
    testing.expect(t, publish(&a, id, "zzz", 1, 2, other[:]), "the cap was shared")
}

// A run is DOCUMENT BYTES, so one of them crosses a line end. The renderer is where it is split,
// and only for the lines the viewport is showing.
@(test)
a_run_is_bytes_and_the_renderer_splits_it_by_line :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)
    snap := store.store_snapshot(&a.docs, id)
    defer txt.snapshot_release(snap)

    // From "a = 1" on line 0 through "let" on line 1: one publish, two drawn rows.
    across := [?]store.Span{{lo = 4, hi = 13, fg = RED, attrs = 1, set = {.Fg, .Attrs}}}
    testing.expect(t, publish(&a, id, "syntax", 0, 20, across[:]))

    out := app.doc_styles(&a, id, nil, &snap.text, nil, 0, 4)
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0].line, 0)
    testing.expect_value(t, out[0].lo, 4) // to the end of "let a = 1", the newline excluded
    testing.expect_value(t, out[0].hi, 9)
    testing.expect_value(t, out[1].line, 1)
    testing.expect_value(t, out[1].lo, 0)
    testing.expect_value(t, out[1].hi, 3)
    testing.expect_value(t, out[0].attrs, gfx.Attrs{.Bold})

    // And only what is on screen costs anything: the store holds both, one row asks for one.
    one := app.doc_styles(&a, id, nil, &snap.text, nil, 1, 1)
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
    defer close_spans_app(&a)

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

    // The same for a publisher: one name is one bucket, so a reload takes back what the config
    // line ranked rather than landing beside it.
    who := app.producer_intern(&a, "syntax")
    testing.expect_value(t, app.producer_intern(&a, "syntax"), who)
    testing.expect(t, app.producer_intern(&a, "lsp") != who, "two names took one bucket")
    testing.expect_value(t, app.producer_name(&a, who), "syntax")
}

// THE POINT OF STORING TOKENS. The store holds ids and the draw resolves them, so swapping the
// theme retints what is already published — no producer republishes, and a resolver that crept
// back upstream of the draw is what this fails on.
@(test)
a_theme_switch_retints_with_no_republish :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)
    app.ring_add(&a, id)

    alert := [?]store.Span{fg(0, 3, u32(gfx.Token.Alert))}
    testing.expect(t, publish(&a, id, "syntax", 0, 9, alert[:]))
    app.surface_draw(&a)

    snap := store.store_snapshot(&a.docs, id)
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    gut := view.gutter_width(&snap.text, d)
    cell := gfx.grid_at(panel_grid(&a), gut, 0)
    if !testing.expect(t, cell != nil, "nothing was drawn") {
        return
    }
    testing.expect_value(t, cell.fg, a.theme[.Alert])

    a.theme[.Alert] = {0, 1, 0}
    app.surface_draw(&a)
    testing.expect_value(t, gfx.grid_at(panel_grid(&a), gut, 0).fg, a.theme[.Alert])
}

// Spans ride a transaction, so the runs and the bytes they cover land at ONE generation: a
// publish against a document that has moved is dropped whole, exactly like an edit.
@(test)
a_stale_span_publish_is_dropped_with_its_transaction :: proc(t: ^testing.T) {
    a, id, ok := spans_app(t)
    if !ok {
        return
    }
    defer close_spans_app(&a)

    who := app.producer_intern(&a, "syntax")
    gen, _ := store.store_gen(&a.docs, id)
    list := [?]store.Span{fg(0, 3, RED)}
    // Both were written against `gen`, in one frame. The edit lands and moves it, so the
    // publish behind it is measured against bytes that are gone and goes whole.
    store.store_submit(&a.docs, id, gen, {{0, 0, "x", 0, 0}})
    store.store_submit(&a.docs, id, gen, nil, nil,
                       store.Spans{who = who, lo = 0, hi = 9, list = list[:]})
    store.store_drain(&a.docs)
    testing.expect_value(t, len(merged(&a, id, 0, 20)), 0)

    moved, _ := store.store_gen(&a.docs, id)
    store.store_submit(&a.docs, id, moved, nil, nil,
                       store.Spans{who = who, lo = 0, hi = 9, list = list[:]})
    store.store_drain(&a.docs)
    testing.expect_value(t, len(merged(&a, id, 0, 20)), 1)
}

// --- helpers ---

// The App owns the interned style names and whatever the file said about the order.
@(private = "file")
close_spans_app :: proc(a: ^app.App) {
    app.tokens_destroy(a)
    app.config_destroy(&a.config)
    close_app(a)
}

// A document in a KIND, which is the section a `spans` line is written under.
@(private = "file")
kinded_doc :: proc(a: ^app.App, kind: input.Kind) -> store.Id {
    id := store.store_open(&a.docs, SOURCE)
    gen, _ := store.store_gen(&a.docs, id)
    d := desc.new_from({kind = kind, ctx = .Text, editable = true, tab_width = 4})
    store.store_submit(&a.docs, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&a.docs)
    return id
}

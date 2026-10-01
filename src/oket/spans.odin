package main

import "lues:lues"
import "lues:pt"
import "../desc"
import "../shape"
import "../gfx"
import "../store"
import "../view"

// The renderer's read of the span store (lues docs/spans.odin). The store speaks DOCUMENT BYTES,
// because a run that crosses a line end is one run; the renderer draws a row at a time, so this
// is where a run is split by line.
//
// Only the lines about to be drawn are asked for. That is what keeps a 1 MB file's colours off
// the frame: the store holds them all, and the cost per frame is one screen's worth. Who is
// merged in what order is producers.odin's answer.

// The lines a viewport shows, [first, last) of the DRAWN document, and the ORIGINAL's bytes
// behind them. `rows` is the body's height, which is a SUPERSET of the lines drawn — wrapping
// only ever costs more rows per line, never fewer.
shown :: proc(t: ^pt.Text, dv: ^view.Derived, top, rows: int) -> (first, last, lo, hi: int, ok: bool) {
    lines := pt.text_line_count(t)
    first = clamp(top, 0, max(lines - 1, 0))
    last = min(first + max(rows, 1), lines)
    if lines == 0 || last <= first {
        return
    }
    lo = pt.text_line_start(t, first)
    _, hi = pt.text_line_range(t, last - 1)
    if dv != nil {
        lo, _ = view.src_off(dv, lo)
        hi, _ = view.src_off(dv, hi)
    }
    return first, last, lo, hi, true
}

// The fields on the lines a viewport shows.
shown_fields :: proc(a: ^App, id: store.Id, t: ^pt.Text, dv: ^view.Derived, top, rows: int) -> []desc.Field {
    _, _, lo, hi, ok := shown(t, dv, top, rows)
    if !ok {
        return nil
    }
    orig := view.original(dv, t)
    return doc_fields(a, id, orig, pt.text_line_at_off(orig, lo), pt.text_line_at_off(orig, hi) + 1)
}

// Every run on the lines the viewport is showing, in DRAWN lines and paint order: the store's,
// then the links among `fields`, then `live` (the one a click would take), then what the view
// stages painted.
//
// The store and the links speak the ORIGINAL (§6), so they go through the map; a stage's runs
// were measured over the drawn document already. `dv` is nil for a document nobody derived.
doc_styles :: proc(
    a: ^App,
    id: store.Id,
    d: ^desc.Descriptor,
    t: ^pt.Text,
    dv: ^view.Derived,
    top, rows: int,
    fields: []desc.Field = nil,
    live: []view.Style = nil,
) -> []view.Style {
    first, last, lo, hi, ok := shown(t, dv, top, rows)
    if !ok {
        return nil
    }
    orig := view.original(dv, t)
    runs := make([dynamic]view.Run, 0, 64, context.temp_allocator)
    for sp in store.store_spans(a.docs, id, lo, hi, spans_order(a, id)) {
        if sp.key != 0 {
            continue // data, not a look
        }
        // A channel nobody set is the theme's, said as its TOKEN. The store merged whoever did
        // set it and stopped there, because a store that filled a colour in would have made
        // every publisher opaque again.
        append(&runs, view.Run{sp.lo, sp.hi, {
            fg    = .Fg in sp.set ? sp.fg : u32(gfx.Token.Fg),
            bg    = .Bg in sp.set ? sp.bg : u32(gfx.Token.Bg),
            attrs = .Attrs in sp.set ? transmute(shape.Attrs)sp.attrs : {},
        }})
    }
    line_runs(&runs, orig, doc_links(a, d, fields))
    line_runs(&runs, orig, live)
    drawn := view.forward(dv, runs[:])
    if stages := views_over(a, id); len(stages) > 0 {
        both := make([dynamic]view.Run, 0, len(drawn) + len(stages), context.temp_allocator)
        append(&both, ..drawn)
        append(&both, ..stages)
        drawn = both[:]
    }
    return view.cut_lines(t, drawn, first, last)
}

// Styles keyed by a line of `t`, as runs over its bytes.
@(private = "file")
line_runs :: proc(out: ^[dynamic]view.Run, t: ^pt.Text, styles: []view.Style) {
    for st in styles {
        at := pt.text_line_start(t, st.line)
        append(out, view.Run{at + st.lo, at + st.hi, st})
    }
}

// The data spans over ORIGINAL lines [first, last), read back as fields: a name, where it sits
// on its line, and its value. A run published with no value is worth its own bytes. A run that
// crosses a line end is cut at it.
doc_fields :: proc(a: ^App, id: store.Id, orig: ^pt.Text, first, last: int,
                   alloc := context.temp_allocator) -> []desc.Field {
    lines := pt.text_line_count(orig)
    first, last := max(first, 0), min(last, lines)
    if first >= last {
        return nil
    }
    lo := pt.text_line_start(orig, first)
    _, hi := pt.text_line_range(orig, last - 1)
    out := make([dynamic]desc.Field, alloc)
    row, at := -1, 0
    bytes: []u8
    for sp in store.store_spans(a.docs, id, lo, max(hi, lo + 1), spans_order(a, id)) {
        if sp.key == 0 {
            continue // a look, not data
        }
        if line := pt.text_line_at_off(orig, sp.lo); line != row {
            row, at = line, pt.text_line_start(orig, line)
            bytes = pt.text_line(orig, line, alloc)
        }
        f_hi := min(sp.hi - at, len(bytes))
        f_lo := min(sp.lo - at, f_hi)
        value := sp.text if sp.valued else string(bytes[f_lo:f_hi])
        append(&out, desc.Field{row, lues.token_name(a.kernel, lues.Token(sp.key)), f_lo, f_hi, value})
    }
    return out[:]
}

package main

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

// Every run on the lines the viewport is showing, in DRAWN lines and paint order: the store's,
// then the links, then `live` (the one a click would take), then what the view stages painted.
// `rows` is the body's height, which is a SUPERSET of the lines drawn — wrapping only ever
// costs more rows per line, never fewer.
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
    live: []view.Style = nil,
) -> []view.Style {
    lines := pt.text_line_count(t)
    first := clamp(top, 0, max(lines - 1, 0))
    last := min(first + max(rows, 1), lines)
    if lines == 0 || last <= first {
        return nil
    }
    lo := pt.text_line_start(t, first)
    _, hi := pt.text_line_range(t, last - 1)
    orig := view.original(dv, t)
    if dv != nil {
        lo, _ = view.src_off(dv, lo)
        hi, _ = view.src_off(dv, hi)
    }
    runs := make([dynamic]view.Run, 0, 64, context.temp_allocator)
    for sp in store.store_spans(a.docs, id, lo, hi, spans_order(a, id)) {
        // A channel nobody set is the theme's, said as its TOKEN. The store merged whoever did
        // set it and stopped there, because a store that filled a colour in would have made
        // every publisher opaque again.
        append(&runs, view.Run{sp.lo, sp.hi, {
            fg    = .Fg in sp.set ? sp.fg : u32(gfx.Token.Fg),
            bg    = .Bg in sp.set ? sp.bg : u32(gfx.Token.Bg),
            attrs = .Attrs in sp.set ? transmute(shape.Attrs)sp.attrs : {},
        }})
    }
    olines := pt.text_line_count(orig)
    line_runs(&runs, orig, doc_links(a, d, pt.text_line_at_off(orig, lo),
                                     min(pt.text_line_at_off(orig, hi) + 1, olines)))
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

package main

import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"

// The renderer's read of the span store (store/spans.odin). The store speaks DOCUMENT BYTES,
// because a run that crosses a line end is one run; the renderer draws a row at a time, so this
// is where a run is split by line.
//
// Only the lines about to be drawn are asked for. That is what keeps a 1 MB file's colours off
// the frame: the store holds them all, and the cost per frame is one screen's worth. Who is
// merged in what order is producers.odin's answer.

// The runs covering the lines the viewport is showing. `rows` is the body's height, which is a
// SUPERSET of the lines drawn — wrapping only ever costs more rows per line, never fewer.
//
// TWO SPACES, and the split is §6's: the viewport counts lines of the DRAWN document, while the
// store holds bytes of the ORIGINAL — nothing was ever measured over a fold marker. `t` is what
// is drawn and `dv` is the map, which is nil and the identity for a document nobody derived.
doc_styles :: proc(
    a: ^App,
    id: store.Id,
    d: ^desc.Descriptor,
    t: ^txt.Text,
    dv: ^view.Derived,
    top, rows: int,
) -> []view.Style {
    lines := txt.text_line_count(t)
    first := clamp(top, 0, max(lines - 1, 0))
    last := min(first + max(rows, 1), lines)
    if lines == 0 || last <= first {
        return nil
    }
    lo := txt.text_line_start(t, first)
    _, hi := txt.text_line_range(t, last - 1)
    orig := view.original(dv, t)
    if dv != nil {
        lo, _ = view.src_off(dv, lo)
        hi, _ = view.src_off(dv, hi)
    }
    olines := txt.text_line_count(orig)
    // The rows a click would act on, over the same lines and in the same coordinates. Merged
    // rather than concatenated, because line_styles binary-searches this list.
    links := doc_links(a, d, txt.text_line_at_off(orig, lo),
                       min(txt.text_line_at_off(orig, hi) + 1, olines))
    spans := store.store_spans(&a.docs, id, lo, hi, spans_order(a, id))
    if len(spans) == 0 {
        return links
    }
    out := make([dynamic]view.Style, 0, len(spans), context.temp_allocator)
    for sp in spans {
        // Spans arrive sorted and non-overlapping and each one's pieces come out in line
        // order, so appending in this order leaves the result sorted by line — which is what
        // view.line_styles binary-searches.
        for line := txt.text_line_at_off(orig, sp.lo); line < olines; line += 1 {
            a_off, b_off := txt.text_line_range(orig, line)
            if a_off >= sp.hi {
                break
            }
            cut_lo, cut_hi := max(sp.lo, a_off) - a_off, min(sp.hi, b_off) - a_off
            if cut_lo < cut_hi {
                append(&out, view.Style{
                    line  = line,
                    lo    = cut_lo,
                    hi    = cut_hi,
                    // A channel nobody set is the theme's, said as its TOKEN. The store merged
                    // whoever did set it and stopped there, because a store that filled a
                    // colour in would have made every publisher opaque again.
                    fg    = .Fg in sp.set ? sp.fg : u32(gfx.Token.Fg),
                    bg    = .Bg in sp.set ? sp.bg : u32(gfx.Token.Bg),
                    attrs = .Attrs in sp.set ? transmute(gfx.Attrs)sp.attrs : {},
                })
            }
        }
    }
    return styles_over(out[:], links)
}

// Two lists, each already sorted by line, into one that is. `over` lands AFTER `under` on a line
// they share: view.paint writes whole cells in list order, so the later run is the one that
// shows — which is how a link draws over the syntax beneath it.
styles_over :: proc(under, over: []view.Style,
                    allocator := context.temp_allocator) -> []view.Style {
    if len(over) == 0 {
        return under
    }
    if len(under) == 0 {
        return over
    }
    out := make([dynamic]view.Style, 0, len(under) + len(over), allocator)
    i, j := 0, 0
    for i < len(under) && j < len(over) {
        if under[i].line <= over[j].line {
            append(&out, under[i])
            i += 1
        } else {
            append(&out, over[j])
            j += 1
        }
    }
    append(&out, ..under[i:])
    append(&out, ..over[j:])
    return out[:]
}

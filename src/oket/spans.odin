package main

import "../gfx"
import "../store"
import "../txt"
import "../view"

// The renderer's read of the span store (store/spans.odin). The store speaks DOCUMENT BYTES,
// because a run that crosses a line end is one run; the renderer draws a row at a time, so this
// is where a run is split by line.
//
// Only the lines about to be drawn are asked for. That is what keeps a 1 MB file's colours off
// the frame: the store holds them all, and the cost per frame is one screen's worth.

// The runs covering the lines the viewport is showing. `rows` is the body's height, which is a
// SUPERSET of the lines drawn — wrapping only ever costs more rows per line, never fewer.
doc_styles :: proc(a: ^App, id: store.Id, t: ^txt.Text, top, rows: int) -> []view.Style {
    lines := txt.text_line_count(t)
    first := clamp(top, 0, max(lines - 1, 0))
    last := min(first + max(rows, 1), lines)
    if lines == 0 || last <= first {
        return nil
    }
    lo := txt.text_line_start(t, first)
    _, hi := txt.text_line_range(t, last - 1)
    spans := store.store_spans(&a.docs, id, lo, hi)
    if len(spans) == 0 {
        return nil
    }
    out := make([dynamic]view.Style, 0, len(spans), context.temp_allocator)
    for sp in spans {
        // Spans arrive sorted and non-overlapping and each one's pieces come out in line
        // order, so appending in this order leaves the result sorted by line — which is what
        // view.line_styles binary-searches.
        for line := txt.text_line_at_off(t, sp.lo); line < lines; line += 1 {
            a_off, b_off := txt.text_line_range(t, line)
            if a_off >= sp.hi {
                break
            }
            cut_lo, cut_hi := max(sp.lo, a_off) - a_off, min(sp.hi, b_off) - a_off
            if cut_lo < cut_hi {
                append(&out, view.Style{
                    line  = line,
                    lo    = cut_lo,
                    hi    = cut_hi,
                    fg    = sp.fg,
                    bg    = sp.bg,
                    attrs = transmute(gfx.Attrs)sp.attrs,
                })
            }
        }
    }
    return out[:]
}

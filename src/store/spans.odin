package store

import "core:slice"
import "../desc"

// The span store (§5's `spans`, §9). The kernel STORES style runs and never computes them: a
// parser, a linter, a search and the terminal all publish here, and whoever draws the document
// reads one merged answer. Nothing below this line knows what a keyword is.
//
// A span is DOCUMENT BYTES, not a line and a column. A line number is a display convenience,
// and making it the unit costs every run that crosses a line end — a block comment, a here
// document, a TUI's full-width bar. The renderer splits by line where it draws.

// Who published, declared in `desc` because the SEAM names it too and `plug` mirrors txt's
// layouts rather than importing them (`plug_read.odin`'s size asserts). The store's own name
// for it is here, beside the runs it orders.
Layer :: desc.Layer

// One run, and what it draws as. The colour is RESOLVED: a plugin names a style TOKEN and the
// seam resolves it against the theme on the way in, the same way it converts a descriptor. The
// terminal is the kernel and publishes what libvterm gave it, which is a colour SGR named and
// no theme can have an opinion about.
Span :: struct {
    lo, hi: int,
    fg, bg: [3]f32,
    attrs:  u8, // the renderer's attribute bits, carried and never read here
}

// One layer's range-scoped replace, as it rides a transaction. Everything the layer held inside
// [lo, hi) goes and `list` takes its place.
Spans :: struct {
    layer:  Layer,
    lo, hi: int,
    list:   []Span, // owned by the transaction until the drain applies it
}

// Per layer per document, because one publisher going quiet must leave the others' colours
// alone. Bounded, because a layer that publishes a whole large file on every edit is the
// failure this cap names: past it the rest of the document draws plain, and a refusal a
// publisher can see beats a store that grows with the file.
SPAN_MAX :: 1 << 14

// Everything this layer held inside [lo, hi) goes, and `pub.list` takes its place. A span
// straddling an edge is CLIPPED rather than dropped, so republishing one screen cannot delete
// the tail of a string that began above it.
@(private)
spans_apply :: proc(slot: ^Slot, pub: Spans) -> bool {
    if pub.hi < pub.lo {
        return false
    }
    fresh := spans_clean(pub.list, pub.lo, pub.hi)
    kept := slot.spans[pub.layer]
    out := make([dynamic]Span, 0, len(kept) + len(fresh), context.temp_allocator)
    // Below the range, then the range, then above it. Built in that order the result is sorted
    // by construction, so a publish costs two walks rather than a sort of the whole layer —
    // which is the difference between a frame and several when a parse publishes per frame.
    for old in kept {
        if old.lo < pub.lo {
            append(&out, span_cut(old, old.lo, min(old.hi, pub.lo)))
        }
    }
    append(&out, ..fresh)
    for old in kept {
        if old.hi > pub.hi {
            append(&out, span_cut(old, max(old.lo, pub.hi), old.hi))
        }
    }
    // Bounded on what SURVIVES, not on what arrives: a republish replaces, so a layer sitting
    // at the cap can still republish itself, and a refusal leaves the store as it was.
    if len(out) > SPAN_MAX {
        return false
    }
    clear(&slot.spans[pub.layer])
    append(&slot.spans[pub.layer], ..out[:])
    return true
}

// Every layer over [lo, hi), merged by the priority above and clipped to the range: flat, in
// document order, nothing overlapping. The caller paints it straight and merges nothing.
store_spans :: proc(s: ^Store, id: Id, lo, hi: int,
                    alloc := context.temp_allocator) -> []Span {
    slot, ok := resolve(s, id)
    if !ok || hi <= lo {
        return nil
    }
    merged: []Span
    for layer in Layer {
        merged = spans_overlay(merged, spans_clip(slot.spans[layer][:], lo, hi))
    }
    return slice.clone(merged, alloc)
}

// --- internals ---

// A publisher's spans are untrusted: out of order, overlapping, reversed and outside the range
// it named are all things this has to survive. Clipped to [lo, hi), sorted, and an overlap
// resolved in favour of whichever starts first.
@(private = "file")
spans_clean :: proc(list: []Span, lo, hi: int) -> []Span {
    out := make([dynamic]Span, 0, len(list), context.temp_allocator)
    for sp in list {
        if sp.hi <= sp.lo {
            continue
        }
        a, b := max(sp.lo, lo), min(sp.hi, hi)
        if a < b {
            append(&out, span_cut(sp, a, b))
        }
    }
    slice.sort_by(out[:], proc(x, y: Span) -> bool {return x.lo < y.lo})
    at := 0
    for sp in out {
        if at > 0 && sp.lo < out[at - 1].hi {
            continue // it overlaps the one before it; the first span wins
        }
        out[at] = sp
        at += 1
    }
    return out[:at]
}

@(private = "file")
span_cut :: proc(sp: Span, lo, hi: int) -> Span {
    out := sp
    out.lo, out.hi = lo, hi
    return out
}

// One layer's spans over [lo, hi). Sorted and non-overlapping already, so this is a walk from
// the first span that reaches into the range.
@(private = "file")
spans_clip :: proc(list: []Span, lo, hi: int) -> []Span {
    at, _ := slice.binary_search_by(list, lo, proc(sp: Span, key: int) -> slice.Ordering {
        return .Less if sp.hi <= key else .Greater
    })
    out := make([dynamic]Span, 0, 64, context.temp_allocator)
    for i := at; i < len(list) && list[i].lo < hi; i += 1 {
        a, b := max(list[i].lo, lo), min(list[i].hi, hi)
        if a < b {
            append(&out, span_cut(list[i], a, b))
        }
    }
    return out[:]
}

// `top` wins wherever the two meet and what is left of `base` fills in around it. Both are
// sorted and non-overlapping, so one sweep does it and the result is the same shape — which is
// what lets the layers stack by folding this over them in priority order.
@(private = "file")
spans_overlay :: proc(base, top: []Span) -> []Span {
    if len(top) == 0 {
        return base
    }
    if len(base) == 0 {
        return top
    }
    out := make([dynamic]Span, 0, len(base) + len(top), context.temp_allocator)
    i, j, at := 0, 0, min(base[0].lo, top[0].lo)
    for {
        for i < len(base) && base[i].hi <= at {
            i += 1
        }
        for j < len(top) && top[j].hi <= at {
            j += 1
        }
        if i >= len(base) && j >= len(top) {
            break
        }
        if j < len(top) && top[j].lo <= at {
            append(&out, span_cut(top[j], at, top[j].hi))
            at = top[j].hi
        } else if i < len(base) && base[i].lo <= at {
            // Stopping where the next top span starts is what makes this one sweep: the rest
            // of the base span is picked up on a later pass round the loop.
            end := base[i].hi
            if j < len(top) {
                end = min(end, top[j].lo)
            }
            append(&out, span_cut(base[i], at, end))
            at = end
        } else {
            next := max(int) // a hole in both: jump to whichever starts next
            if i < len(base) {
                next = min(next, base[i].lo)
            }
            if j < len(top) {
                next = min(next, top[j].lo)
            }
            at = next
        }
    }
    return out[:]
}

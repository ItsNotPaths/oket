package store

import "core:slice"
import "../desc"

// The span store (§5's `spans`, §9, VIEWS §8). The kernel STORES style runs and never computes
// them: a parser, a linter, a search and the terminal all publish here, and whoever draws the
// document reads one merged answer. Nothing below this line knows what a keyword is.
//
// A span is DOCUMENT BYTES, not a line and a column. A line number is a display convenience,
// and making it the unit costs every run that crosses a line end — a block comment, a here
// document, a TUI's full-width bar. The renderer splits by line where it draws.
//
// THE BUCKET IS THE PUBLISHER, and the caller says in what order they stack. Nobody can publish
// under another producer's name, so nobody can range-replace another's runs.

// Who published, as an id the kernel interns from a name. The store never sees the name: it
// keys, and the order it is read in is the caller's answer (`store_spans`).
Producer :: distinct u16

// One run, and what it draws as. The colour is NOT resolved: `fg` and `bg` are token ids the
// renderer reads through the palette at draw time (gfx.COLOR_LIT marks the literal form), so a
// theme switch is a palette swap and the next frame — never a republish. The terminal is the
// kernel and writes what libvterm gave it as literals, which is a colour an SGR named and no
// theme can have an opinion about.
//
// `set` is which of the three a run has an opinion about. A field it does not set is not black
// and not the theme's — it is whatever is under it, decided at merge time.
Span :: struct {
    lo, hi: int,
    fg, bg: u32, // a token id, or a literal under gfx.COLOR_LIT
    attrs:  u8, // the renderer's attribute bits, carried and never read here
    set:    desc.Chans,
}

// One producer's range-scoped replace, as it rides a transaction. Everything that producer held
// inside [lo, hi) goes and `list` takes its place.
Spans :: struct {
    who:    Producer,
    lo, hi: int,
    list:   []Span, // owned by the transaction until the drain applies it
}

// Per producer per document, because one publisher going quiet must leave the others' colours
// alone. Bounded, because a publisher that publishes a whole large file on every edit is the
// failure this cap names: past it the rest of the document draws plain, and a refusal a
// publisher can see beats a store that grows with the file.
//
// PER PRODUCER, so one publisher cannot starve another out of the cap.
SPAN_MAX :: 1 << 14

// One publisher's runs over one document. Kept in first-publish order, which nothing reads:
// the z-order is the caller's, handed to `store_spans` per read.
@(private)
Bucket :: struct {
    who:  Producer,
    list: [dynamic]Span,
}

// Everything this producer held inside [lo, hi) goes, and `pub.list` takes its place. A span
// straddling an edge is CLIPPED rather than dropped, so republishing one screen cannot delete
// the tail of a string that began above it.
@(private)
spans_apply :: proc(slot: ^Slot, pub: Spans) -> bool {
    if pub.hi < pub.lo {
        return false
    }
    fresh := spans_clean(pub.list, pub.lo, pub.hi)
    b := bucket_for(slot, pub.who)
    out := make([dynamic]Span, 0, len(b.list) + len(fresh), context.temp_allocator)
    // Below the range, then the range, then above it. Built in that order the result is sorted
    // by construction, so a publish costs two walks rather than a sort of the whole bucket —
    // which is the difference between a frame and several when a parse publishes per frame.
    for old in b.list {
        if old.lo < pub.lo {
            append(&out, span_cut(old, old.lo, min(old.hi, pub.lo)))
        }
    }
    append(&out, ..fresh)
    for old in b.list {
        if old.hi > pub.hi {
            append(&out, span_cut(old, max(old.lo, pub.hi), old.hi))
        }
    }
    // Bounded on what SURVIVES, not on what arrives: a republish replaces, so a producer
    // sitting at the cap can still republish itself, and a refusal leaves the store as it was.
    if len(out) > SPAN_MAX {
        return false
    }
    clear(&b.list)
    append(&b.list, ..out[:])
    return true
}

// Every producer over [lo, hi), merged in the order `order` names them and clipped to the
// range: flat, in document order, nothing overlapping. The caller paints it straight and merges
// nothing.
//
// LATER DRAWS OVER EARLIER, per channel. A producer the order does not name is not read at all,
// which is the caller's decision to make: the kernel's own order is total (spans.odin).
store_spans :: proc(s: ^Store, id: Id, lo, hi: int, order: []Producer,
                    alloc := context.temp_allocator) -> []Span {
    slot, ok := resolve(s, id)
    if !ok || hi <= lo {
        return nil
    }
    merged: []Span
    for who in order {
        for &b in slot.spans {
            if b.who == who {
                merged = spans_overlay(merged, spans_clip(b.list[:], lo, hi))
            }
        }
    }
    return slice.clone(merged, alloc)
}

// A producer's runs, everywhere. What unload calls: a plugin's colours go with it, and nobody
// else's move (§8).
store_spans_forget :: proc(s: ^Store, who: Producer) {
    for &slot in s.slots {
        for &b in slot.spans {
            if b.who == who {
                clear(&b.list)
            }
        }
    }
}

// --- internals ---

@(private)
bucket_for :: proc(slot: ^Slot, who: Producer) -> ^Bucket {
    for &b in slot.spans {
        if b.who == who {
            return &b
        }
    }
    append(&slot.spans, Bucket{who = who})
    return &slot.spans[len(slot.spans) - 1]
}

// A publisher's spans are untrusted: out of order, overlapping, reversed and outside the range
// it named are all things this has to survive. Clipped to [lo, hi), sorted, and an overlap
// resolved in favour of whichever starts first.
//
// A run that sets no channel is dropped here rather than stored: it says nothing, and the merge
// would carry it to the renderer to change nothing.
@(private = "file")
spans_clean :: proc(list: []Span, lo, hi: int) -> []Span {
    out := make([dynamic]Span, 0, len(list), context.temp_allocator)
    for sp in list {
        if sp.hi <= sp.lo || sp.set == {} {
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

// One producer's spans over [lo, hi). Sorted and non-overlapping already, so this is a walk from
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

// TOP WINS PER CHANNEL, per byte, and what `top` leaves unset comes from `base`. Two producers
// at one byte are usually not competing for the same thing: a parser says `fg`, a linter says
// `underline`, a search says `bg`, and all three want to be visible at once.
//
// The cost is a run wherever ANY channel changes rather than wherever the winning span does, so
// the merged list is longer and shorter-runned. One sweep, and the output contract is the one
// it has always been: flat, sorted, non-overlapping.
@(private = "file")
spans_overlay :: proc(base, top: []Span) -> []Span {
    if len(top) == 0 {
        return base
    }
    if len(base) == 0 {
        return top
    }
    out := make([dynamic]Span, 0, len(base) + len(top), context.temp_allocator)
    i, j := 0, 0
    at := min(base[0].lo, top[0].lo)
    for i < len(base) || j < len(top) {
        i = span_seek(base, i, at)
        j = span_seek(top, j, at)
        b, hold_b := span_at(base, i, at)
        t, hold_t := span_at(top, j, at)
        // The next edge either list has: past it the answer is a different pair of spans, and
        // one run reaches exactly that far.
        end := max(int)
        end = min(end, hold_b ? b.hi : span_next(base, i, at))
        end = min(end, hold_t ? t.hi : span_next(top, j, at))
        if end == max(int) {
            break
        }
        if hold_b || hold_t {
            run := span_merge(b, t, hold_b, hold_t)
            run.lo, run.hi = at, end
            spans_push(&out, run)
        }
        at = end
    }
    return out[:]
}

// The first span not wholly behind `at`.
@(private = "file")
span_seek :: proc(list: []Span, from, at: int) -> int {
    i := from
    for i < len(list) && list[i].hi <= at {
        i += 1
    }
    return i
}

// The span covering `at`, if the one at `i` does.
@(private = "file")
span_at :: proc(list: []Span, i, at: int) -> (sp: Span, held: bool) {
    if i < len(list) && list[i].lo <= at && at < list[i].hi {
        return list[i], true
    }
    return {}, false
}

// Where this list next has something to say, or max(int) if it never does again.
@(private = "file")
span_next :: proc(list: []Span, i, at: int) -> int {
    return i < len(list) && list[i].lo > at ? list[i].lo : max(int)
}

// `top`'s channels, then `base`'s for the ones top left unset.
@(private = "file")
span_merge :: proc(base, top: Span, hold_b, hold_t: bool) -> (out: Span) {
    if hold_b {
        out = base
    }
    if !hold_t {
        return out
    }
    if .Fg in top.set {
        out.fg = top.fg
    }
    if .Bg in top.set {
        out.bg = top.bg
    }
    if .Attrs in top.set {
        out.attrs = top.attrs
    }
    out.set |= top.set
    return out
}

// Adjacent runs saying the same thing are one run: the sweep cuts at every edge either list
// has, and most of those edges do not change what is drawn.
@(private = "file")
spans_push :: proc(out: ^[dynamic]Span, run: Span) {
    if len(out) > 0 {
        last := &out[len(out) - 1]
        if last.hi == run.lo && span_same(last^, run) {
            last.hi = run.hi
            return
        }
    }
    append(out, run)
}

@(private = "file")
span_same :: proc(x, y: Span) -> bool {
    return x.fg == y.fg && x.bg == y.bg && x.attrs == y.attrs && x.set == y.set
}

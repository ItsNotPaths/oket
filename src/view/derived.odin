package view

import "../txt"

// The position map (VIEWS.md §6). A view stage is handed a document and returns EDITS against
// it, so what is drawn is a piece table over the ORIGINAL's blocks: unchanged text is the same
// bytes, and only what a stage inserted is new.
//
// Everything that PAINTS goes through here — the mouse hit-test, the caret, the spans, the
// fields, the selection, the gutter numbers and reveal. Motion, edits, undo, find, `:w` and the
// journal never do; they stay in the original, always. A view with no pipeline has no map, and
// every consumer below is then the identity.

// One run of the derived document, and where its bytes came from. This is §6's `Derived_Piece`
// keyed by RUN rather than by storage piece: a fold is three runs whatever the piece list under
// it looks like, so both lookups binary-search a handful of entries and not a thousand.
//
// `src` is non-decreasing across the list. An inserted run has no original bytes, and its `src`
// is where the original resumes — which is what makes "inserted text is not enterable" fall
// out rather than be enforced: a click in a fold marker answers the real byte after it.
Derived_Piece :: struct {
    at, len:  int, // in the derived document
    src:      int, // in the original
    inserted: bool,
}

Derived :: struct {
    src:  ^txt.Text, // the original the runs are measured against
    runs: []Derived_Piece,
}

// One stage's output (§5): bytes [lo, hi) of the stage's input become `text`. Sorted by `lo`
// and disjoint, the rule txt.Splice already carries.
Edit :: struct {
    lo, hi: int,
    text:   []u8,
}

// The document `edits` derives from `t`, and the map back to it. Pieces point into `t`'s blocks
// so unchanged text is not copied; one block of `alloc` holds every inserted run.
//
// The result borrows `t`'s blocks and lives in `alloc`, which is the frame's: a derived document
// is rebuilt when the generation moves, never freed run by run.
derive :: proc(
    t: ^txt.Text,
    edits: []Edit,
    alloc := context.temp_allocator,
) -> (
    txt.Text,
    Derived,
) {
    n := 0
    for e in edits {
        n += len(e.text)
    }
    ins := make([]u8, n, alloc)
    blocks := make([][]u8, len(t.blocks) + 1, alloc)
    copy(blocks, t.blocks)
    blocks[len(t.blocks)] = ins

    pieces := make([dynamic]txt.Piece, 0, len(t.pieces) + 2 * len(edits) + 1, alloc)
    runs := make([dynamic]Derived_Piece, 0, 2 * len(edits) + 1, alloc)
    at, cur, used, pi := 0, 0, 0, 0
    for e in edits {
        lo := clamp(e.lo, cur, t.size)
        hi := clamp(e.hi, lo, t.size)
        carry(t, &pieces, &runs, &at, &pi, cur, lo)
        if len(e.text) > 0 {
            copy(ins[used:], e.text)
            append(&pieces, txt.Piece{block = len(t.blocks), off = used, len = len(e.text)})
            append(&runs, Derived_Piece{at = at, len = len(e.text), src = hi, inserted = true})
            at, used = at + len(e.text), used + len(e.text)
        }
        cur = hi
    }
    carry(t, &pieces, &runs, &at, &pi, cur, t.size)
    return txt.text_build(blocks, pieces[:], alloc), {t, runs[:]}
}

// The original's [a, b) as derived pieces, plus the one run naming where they came from. `pi`
// walks the original's piece list ONCE across the whole derivation, because a and b only ever
// go forward — O(pieces + edits), the discipline pt_splice_many already holds.
@(private = "file")
carry :: proc(
    t: ^txt.Text,
    pieces: ^[dynamic]txt.Piece,
    runs: ^[dynamic]Derived_Piece,
    at, pi: ^int,
    a, b: int,
) {
    if b <= a {
        return
    }
    append(runs, Derived_Piece{at = at^, len = b - a, src = a})
    for pi^ < len(t.pieces) {
        p := t.pieces[pi^]
        if p.doc_off >= b {
            break
        }
        if lo, hi := max(p.doc_off, a), min(p.doc_off + p.len, b); lo < hi {
            append(pieces, txt.Piece{block = p.block, off = p.off + lo - p.doc_off, len = hi - lo})
        }
        if p.doc_off + p.len > b {
            break // it runs past this carry, and the next one starts inside it
        }
        pi^ += 1
    }
    at^ += b - a
}

// Two maps as one. A pipeline of N stages leaves N maps — each one back to the stage before it
// — and every consumer of §6 holds ONE, so they are folded here as they are built. `outer` maps
// the newer document to `inner`'s, and the answer maps the newer document to the original.
//
// Runs that meet on both sides are merged, or a chain would fragment the map at every stage
// boundary whether or not the stage touched that byte.
compose :: proc(outer, inner: Derived, alloc := context.temp_allocator) -> Derived {
    under := inner
    out := make([dynamic]Derived_Piece, 0, len(outer.runs) + len(inner.runs), alloc)
    for r in outer.runs {
        if r.inserted {
            s, _ := src_off(&under, r.src)
            join(&out, {at = r.at, len = r.len, src = s, inserted = true})
            continue
        }
        lo, hi := r.src, r.src + r.len
        for i := max(run_at(inner.runs, lo), 0); i < len(inner.runs); i += 1 {
            rn := inner.runs[i]
            if rn.at >= hi {
                break
            }
            x, y := max(rn.at, lo), min(rn.at + rn.len, hi)
            if x >= y {
                continue
            }
            join(&out, {
                at       = r.at + x - lo,
                len      = y - x,
                src      = rn.inserted ? rn.src : rn.src + x - rn.at,
                inserted = rn.inserted,
            })
        }
    }
    return {inner.src, out[:]}
}

// --- the two lookups ---

// A derived offset in the ORIGINAL. `ok` is false inside text a stage inserted, where the answer
// is the byte the original resumes at: §6 rules inserted text unenterable, so a click in a fold
// marker belongs to the real text beside it.
src_off :: proc(dv: ^Derived, off: int) -> (int, bool) {
    i := run_at(dv.runs, off)
    if i < 0 {
        return 0, false
    }
    r := dv.runs[i]
    switch {
    case r.inserted:
        return r.src, false
    case off < r.at + r.len:
        return r.src + off - r.at, true
    }
    return r.src + r.len, false // past the last run
}

// An original offset in the DERIVED document. `ok` is false inside a run a stage deleted, where
// the answer is the cell the cut left behind — no cell on screen stands for those bytes.
view_off :: proc(dv: ^Derived, off: int) -> (int, bool) {
    i := run_at_src(dv.runs, off)
    if i < 0 {
        return 0, false
    }
    r := dv.runs[i]
    switch {
    case r.inserted:
        return r.at, false
    case off < r.src + r.len:
        return r.at + off - r.src, true
    }
    return r.at + r.len, false
}

// The same pair over positions, which is what every consumer of §6 actually holds. A nil map is
// the identity, so no consumer branches on whether anybody derived the document.
src_pos :: proc(dv: ^Derived, t: ^txt.Text, p: txt.Pos) -> (txt.Pos, bool) {
    if dv == nil {
        return p, true
    }
    o, ok := src_off(dv, txt.text_off(t, p))
    return txt.text_pos(dv.src, o), ok
}

view_pos :: proc(dv: ^Derived, t: ^txt.Text, p: txt.Pos) -> (txt.Pos, bool) {
    if dv == nil {
        return p, true
    }
    o, ok := view_off(dv, txt.text_off(dv.src, p))
    return txt.text_pos(t, o), ok
}

// The document being edited: the map's source, or the text itself when nobody derived it.
original :: proc(dv: ^Derived, t: ^txt.Text) -> ^txt.Text {
    return dv == nil ? t : dv.src
}

// The ORIGINAL line a drawn line shows, or -1 when every byte of it was inserted. The first real
// byte decides, so an inlay at the head of a line does not cost the line its number. Identity
// under a nil map.
src_line :: proc(dv: ^Derived, t: ^txt.Text, line: int) -> int {
    if dv == nil {
        return line
    }
    lo, hi := txt.text_line_range(t, line)
    for i := max(run_at(dv.runs, lo), 0); i < len(dv.runs); i += 1 {
        r := dv.runs[i]
        // [lo, hi) is the line WITHOUT its newline, so a run starting at `hi` starts on the
        // terminator and holds none of this line's text. An empty line is the exception: it has
        // no bytes at all, and the run it sits in is the answer.
        if r.at >= hi && r.at > lo {
            break
        }
        if !r.inserted {
            return txt.text_line_at_off(dv.src, r.src + clamp(lo - r.at, 0, r.len))
        }
    }
    return -1
}

// §7's export to motion, and the whole of it: the runs of the ORIGINAL that no cell stands for.
// Deletions only — inserted text needs no entry, because §6 rules it unenterable and motion
// therefore never has to know it is there.
hidden :: proc(dv: ^Derived, alloc := context.temp_allocator) -> []txt.Range {
    out := make([dynamic]txt.Range, 0, len(dv.runs) + 1, alloc)
    end := 0
    for r in dv.runs {
        if r.inserted {
            continue
        }
        cut(&out, dv.src, end, r.src)
        end = r.src + r.len
    }
    cut(&out, dv.src, end, dv.src.size)
    return out[:]
}

// --- internals ---

// Appends, or grows the run before it when the two are one run in both spaces.
@(private = "file")
join :: proc(out: ^[dynamic]Derived_Piece, r: Derived_Piece) {
    if len(out) > 0 {
        p := &out[len(out) - 1]
        fits := p.inserted == r.inserted && p.at + p.len == r.at
        if fits && (r.inserted ? p.src == r.src : p.src + p.len == r.src) {
            p.len += r.len
            return
        }
    }
    append(out, r)
}

@(private = "file")
cut :: proc(out: ^[dynamic]txt.Range, t: ^txt.Text, a, b: int) {
    if b > a {
        append(out, txt.Range{txt.text_pos(t, a), txt.text_pos(t, b)})
    }
}

// The run holding a derived offset: the last one starting at or before it. -1 for an empty map.
@(private = "file")
run_at :: proc(runs: []Derived_Piece, off: int) -> int {
    lo, hi := 0, len(runs)
    for lo < hi {
        mid := (lo + hi) / 2
        if runs[mid].at <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo - 1
}

// The same over `src`, then forward past an inserted run, which shares its resume point with the
// real text after it and must not answer for it.
@(private = "file")
run_at_src :: proc(runs: []Derived_Piece, off: int) -> int {
    lo, hi := 0, len(runs)
    for lo < hi {
        mid := (lo + hi) / 2
        if runs[mid].src <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    i := lo - 1
    for i >= 0 && i + 1 < len(runs) && runs[i].inserted && runs[i + 1].src <= off {
        i += 1
    }
    return i
}

// The parts of one drawn row whose bytes came from [lo, hi) of the ORIGINAL, as byte offsets
// into the row's own line. One part where nothing was cut out, none where the row is text a
// stage inserted, and two or more across a fold — which is why a selection over one paints in
// two pieces, and why a span never colours a marker it was not measured over.
@(private)
parts :: proc(
    dv: ^Derived,
    r: Row,
    dls, lo, hi: int,
    alloc := context.temp_allocator,
) -> [][2]int {
    out := make([dynamic][2]int, 0, 4, alloc)
    a, b := dls + r.lo, dls + r.hi // the row, in derived offsets
    if dv == nil {
        if x, y := max(lo, a), min(hi, b); x < y {
            append(&out, [2]int{x - dls, y - dls})
        }
        return out[:]
    }
    for i := max(run_at(dv.runs, a), 0); i < len(dv.runs); i += 1 {
        rn := dv.runs[i]
        if rn.at >= b {
            break
        }
        if rn.inserted {
            continue
        }
        x := max(rn.at, a, rn.at + lo - rn.src)
        y := min(rn.at + rn.len, b, rn.at + hi - rn.src)
        if x < y {
            append(&out, [2]int{x - dls, y - dls})
        }
    }
    return out[:]
}

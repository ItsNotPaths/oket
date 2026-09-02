package txt

import "core:slice"

// The byte storage under Doc: an ordered list of Pieces, each naming a span of one immutable
// Block. Reading walks the pieces, editing splices the list; nothing already written is ever
// copied or moved, which buys two things:
//   - parsing needs no flat copy — tree-sitter's read callback is handed a piece's span
//   - a snapshot is cheap — a worker clones only `pieces` and `lines`, both small
//
// Block 0 is the file as loaded; every later block is an append chunk. Blocks are only ever
// discarded together, by pt_compact.
//
// Invariants, held by every op:
//   - pieces are in document order, none empty, and `doc_off` is the running byte total
//   - the line index resolves ascending, line 0 starts at 0, and is never empty (an empty
//     document is one empty line)
//   - `size` is the sum of the piece lengths
Piece_Table :: struct {
    blocks:    [dynamic][]u8, // owned; block 0 is the loaded file
    pieces:    [dynamic]Piece,
    size:      int,
    tail:      int, // the block appends go into, -1 before the first
    tail_used: int, // bytes of it already written
    // The line index (below): segments over an append-only pool, never a shifted array.
    line_store: [dynamic]int,
    line_segs:  [dynamic]Line_Seg,
    line_count: int,
}

// A run of consecutive lines whose starts sit at `line_store[at ..< at+n]`, each read back
// with `delta` added. An edit pushes and re-deltas segments; it never rewrites the starts.
//
// This is RAD Debugger's TXT_LineMapRangeNode (src/text/text.h), which holds an unshifted
// ranges array plus a signed delta applied at lookup. The flat array of absolute offsets it
// replaces cost one add per line AFTER the caret on every keystroke, which is O(document) on
// the frame path — the one thing §9 says must never scale with the file.
//
// `first` is the line number of `store[at]`, so a lookup binary-searches segments and then
// binary-searches inside one. Typing at a point splits a segment once and then only bumps
// deltas, so a run of keystrokes adds one segment and not one per key.
Line_Seg :: struct {
    first: int,
    at:    int,
    n:     int,
    delta: int,
}

// Segments accumulate on scattered editing; past this the index is flattened back to one, the
// pool's garbage goes with it, and the cost is amortised the way pt_compact's is.
PT_COMPACT_SEGS :: 2048

// [off, off+len) of blocks[block], sitting at [doc_off, doc_off+len) of the document. `doc_off`
// is what makes an offset resolvable by binary search, so every op that changes a piece's
// length repairs the pieces after it.
Piece :: struct {
    block:   int,
    off:     int,
    len:     int,
    doc_off: int,
}

// Big enough that ordinary typing allocates about once a session. A single append larger than
// this gets a block of its own, so one append is always one piece.
PT_CHUNK :: 64 * 1024

// Reached only by scattered editing — typing runs coalesce into one piece — and pt_compact is
// never called from the edit path, so crossing it costs nothing until a save.
PT_COMPACT_PIECES :: 2048

// --- lifecycle ---

pt_init :: proc(pt: ^Piece_Table) {
    pt.tail = -1
    lines_reset(pt, {0}) // the empty document is one empty line
}

pt_destroy :: proc(pt: ^Piece_Table) {
    for b in pt.blocks {
        delete(b)
    }
    delete(pt.blocks)
    delete(pt.pieces)
    delete(pt.line_store)
    delete(pt.line_segs)
    pt^ = {}
}

// The bytes are cloned into block 0 and every earlier block is dropped, so a load leaves the
// table as compact as it can be.
pt_load :: proc(pt: ^Piece_Table, src: []u8) {
    for b in pt.blocks {
        delete(b)
    }
    clear(&pt.blocks)
    clear(&pt.pieces)
    pt.tail, pt.tail_used, pt.size = -1, 0, len(src)

    append(&pt.blocks, slice.clone(src))
    if len(src) > 0 {
        append(&pt.pieces, Piece{block = 0, off = 0, len = len(src), doc_off = 0})
    }
    lines_reset(pt, {0})
    for c, i in src {
        if c == '\n' {
            lines_push(pt, i + 1)
        }
    }
}

// --- reading ---

pt_line_count :: proc(pt: ^Piece_Table) -> int {
    return pt.line_count
}

// The byte the line begins at. Every read of the index goes through here, which is what let
// the representation underneath change without a caller noticing.
pt_line_start :: proc(pt: ^Piece_Table, line: int) -> int {
    i := seg_at_line(pt, line)
    if i < 0 {
        return 0
    }
    s := pt.line_segs[i]
    return pt.line_store[s.at + clamp(line - s.first, 0, s.n - 1)] + s.delta
}

// Excluding the terminating newline, so no caller has to trim one. Assumes a real line index.
pt_line_range :: proc(pt: ^Piece_Table, line: int) -> (lo, hi: int) {
    lo = pt_line_start(pt, line)
    if line + 1 < pt.line_count {
        return lo, pt_line_start(pt, line + 1) - 1 // one back off the next start: the '\n'
    }
    return lo, pt.size
}

pt_line_len :: proc(pt: ^Piece_Table, line: int) -> int {
    lo, hi := pt_line_range(pt, line)
    return hi - lo
}

// The largest line whose start is at or before `off`. Clamped, so an offset past the end
// answers the last line.
pt_line_at_off :: proc(pt: ^Piece_Table, off: int) -> int {
    lo, hi := 0, pt.line_count
    for lo < hi {
        mid := (lo + hi) / 2
        if pt_line_start(pt, mid) <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return max(0, lo - 1)
}

// As much of the document from `off` as lives in one piece — all tree-sitter's read callback
// wants, and usually a whole line. Borrowed: valid until the next edit.
pt_span :: proc(pt: ^Piece_Table, off: int) -> []u8 {
    i := piece_at(pt.pieces[:], off)
    if i < 0 {
        return nil
    }
    p := pt.pieces[i]
    return pt.blocks[p.block][p.off + off - p.doc_off:p.off + p.len]
}

// The only read that costs a copy; prefer pt_span or pt_line where a borrow will do.
pt_read :: proc(pt: ^Piece_Table, lo, hi: int, alloc := context.allocator) -> []u8 {
    a := clamp(lo, 0, pt.size)
    b := clamp(hi, a, pt.size)
    out := make([]u8, b - a, alloc)
    n := 0
    for n < len(out) {
        src := pt_span(pt, a + n)
        if len(src) == 0 {
            break // a truncated span would otherwise spin
        }
        n += copy(out[n:], src)
    }
    return out
}

// Borrowed out of the block when the line sits inside one piece — the common case, and free —
// and copied into `alloc` only when an edit has split it. Read only, dead after the next edit.
pt_line :: proc(pt: ^Piece_Table, line: int, alloc := context.allocator) -> []u8 {
    lo, hi := pt_line_range(pt, line)
    if hi <= lo {
        return nil
    }
    if s := pt_span(pt, lo); len(s) >= hi - lo {
        return s[:hi - lo]
    }
    return pt_read(pt, lo, hi, alloc)
}

// --- editing ---

// The one mutator, and what a Patch lowers to. Returns the byte delta the callers' own indices
// shift by. The fast path is typing: an insert at the end of a piece that runs to the end of
// the append tail extends it, rather than pushing a piece per keystroke.
pt_splice :: proc(pt: ^Piece_Table, lo, hi: int, text: []u8) -> (delta: int) {
    a := clamp(lo, 0, pt.size)
    b := clamp(hi, a, pt.size)
    if a == b && len(text) == 0 {
        return 0
    }
    delta = len(text) - (b - a)

    pt_splice_lines(pt, a, b, text, delta)

    if a == b && pt_extend_tail(pt, a, text) {
        pt.size += delta
        return
    }

    // Cut at both ends so the replaced region is whole pieces, drop them, and put the new text
    // in their place. `at` is where the removed run began.
    at := pt_split_at(pt, a)
    end := pt_split_at(pt, b)
    remove_range(&pt.pieces, at, end)
    if len(text) > 0 {
        block, off := pt_append(pt, text)
        inject_at(&pt.pieces, at, Piece{block = block, off = off, len = len(text), doc_off = a})
        at += 1
    }
    pt.size += delta
    for i in at ..< len(pt.pieces) {
        pt.pieces[i].doc_off += delta
    }
    return
}

// Asked by the save path and the derivation worker, never by an edit.
pt_should_compact :: proc(pt: ^Piece_Table) -> bool {
    return len(pt.pieces) > PT_COMPACT_PIECES
}

// Flatten to a single block, discarding every old one. The line index is untouched: compaction
// moves bytes between blocks, never within the document.
pt_compact :: proc(pt: ^Piece_Table) {
    flat := pt_read(pt, 0, pt.size)
    for b in pt.blocks {
        delete(b)
    }
    clear(&pt.blocks)
    clear(&pt.pieces)
    append(&pt.blocks, flat)
    if len(flat) > 0 {
        append(&pt.pieces, Piece{block = 0, off = 0, len = len(flat), doc_off = 0})
    }
    pt.tail, pt.tail_used = -1, 0
}

// --- internals ---

// -1 at or past the end. Binary search on doc_off, which is why every op that resizes a piece
// repairs the ones after it.
@(private = "file")
piece_at :: proc(pieces: []Piece, off: int) -> int {
    lo, hi := 0, len(pieces)
    for lo < hi {
        mid := (lo + hi) / 2
        if pieces[mid].doc_off + pieces[mid].len <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo < len(pieces) ? lo : -1
}

// Returns the index of the piece starting at `off` (len(pieces) at the end of the document).
// A no-op when one already ends there, so an aligned edit's two calls cost nothing.
@(private = "file")
pt_split_at :: proc(pt: ^Piece_Table, off: int) -> int {
    i := piece_at(pt.pieces[:], off)
    if i < 0 {
        return len(pt.pieces)
    }
    p := pt.pieces[i]
    if p.doc_off == off {
        return i
    }
    cut := off - p.doc_off
    pt.pieces[i].len = cut
    inject_at(
        &pt.pieces,
        i + 1,
        Piece{block = p.block, off = p.off + cut, len = p.len - cut, doc_off = off},
    )
    return i + 1
}

// `text` at `at` extends the piece ENDING there, when that piece's block bytes also end at the
// append cursor: the first says the insert continues a run this piece holds, the second that
// nothing else was written into the chunk since.
//
// The piece ending at `at`, not the last in the list: typing mid-file splits once on the first
// keystroke, and every keystroke after lands on the end of the piece that split made.
@(private = "file")
pt_extend_tail :: proc(pt: ^Piece_Table, at: int, text: []u8) -> bool {
    if at == 0 || pt.tail < 0 {
        return false
    }
    i := piece_at(pt.pieces[:], at - 1)
    if i < 0 {
        return false
    }
    p := &pt.pieces[i]
    if p.doc_off + p.len != at || p.block != pt.tail || p.off + p.len != pt.tail_used {
        return false
    }
    if pt.tail_used + len(text) > len(pt.blocks[pt.tail]) {
        return false // the chunk is full; take the ordinary path
    }
    copy(pt.blocks[pt.tail][pt.tail_used:], text)
    pt.tail_used += len(text)
    p.len += len(text)
    for k in i + 1 ..< len(pt.pieces) {
        pt.pieces[k].doc_off += len(text)
    }
    return true
}

// A chunk is never grown or moved once written, since a worker may be reading it, so text that
// will not fit opens a fresh one sized to the text. One append is always one contiguous span.
@(private = "file")
pt_append :: proc(pt: ^Piece_Table, text: []u8) -> (block, off: int) {
    if pt.tail < 0 || pt.tail_used + len(text) > len(pt.blocks[pt.tail]) {
        append(&pt.blocks, make([]u8, max(PT_CHUNK, len(text))))
        pt.tail, pt.tail_used = len(pt.blocks) - 1, 0
    }
    off = pt.tail_used
    copy(pt.blocks[pt.tail][off:], text)
    pt.tail_used += len(text)
    return pt.tail, off
}

// Only the lines the replacement straddles are rebuilt, from one scan of `text`; every start
// after them shifts by the byte delta. Called BEFORE the pieces move, while a, b and the old
// index still describe the same document.
@(private = "file")
pt_splice_lines :: proc(pt: ^Piece_Table, a, b: int, text: []u8, delta: int) {
    first := pt_line_at_off(pt, a)
    last := pt_line_at_off(pt, b)

    // The lines the replacement itself introduces. Their starts are absolute already, so they
    // go into the pool with a zero delta and never move again.
    at := len(pt.line_store)
    n := 0
    for c, i in text {
        if c == '\n' {
            append(&pt.line_store, a + i + 1)
            n += 1
        }
    }

    // Cut the segment list at both line boundaries so the replaced lines are whole segments,
    // exactly as pt_splice cuts the piece list at both byte offsets.
    seg_split(pt, first + 1)
    seg_split(pt, last + 1)
    lo, hi := seg_bound(pt, first + 1), seg_bound(pt, last + 1)
    if n > 0 {
        fresh := Line_Seg{first + 1, at, n, 0}
        if hi > lo {
            pt.line_segs[lo] = fresh
            remove_range(&pt.line_segs, lo + 1, hi)
        } else {
            inject_at(&pt.line_segs, lo, fresh)
        }
        lo += 1
    } else if hi > lo {
        remove_range(&pt.line_segs, lo, hi)
    }

    // The whole point: everything after the splice is re-based by one add per SEGMENT, not one
    // per line. A run of keystrokes at one place lands here with the boundary already cut, so
    // it adds no segment at all and this loop is the only work it does.
    line := first + 1 + n
    for i in lo ..< len(pt.line_segs) {
        pt.line_segs[i].first = line
        pt.line_segs[i].delta += delta
        line += pt.line_segs[i].n
    }
    pt.line_count = line
    if len(pt.line_segs) > PT_COMPACT_SEGS {
        lines_compact(pt)
    }
}

// --- the line index ---

// One segment over freshly written starts. Used by load and by compaction, which are the only
// two moments the index has no history to preserve.
@(private = "file")
lines_reset :: proc(pt: ^Piece_Table, starts: []int) {
    clear(&pt.line_store)
    clear(&pt.line_segs)
    append(&pt.line_store, ..starts)
    append(&pt.line_segs, Line_Seg{0, 0, len(starts), 0})
    pt.line_count = len(starts)
}

// Only valid while the last segment runs to the end of the pool, which is true during a load.
@(private = "file")
lines_push :: proc(pt: ^Piece_Table, start: int) {
    append(&pt.line_store, start)
    pt.line_segs[len(pt.line_segs) - 1].n += 1
    pt.line_count += 1
}

// The segment holding `line`, by binary search on `first`. -1 only for an empty index.
@(private = "file")
seg_at_line :: proc(pt: ^Piece_Table, line: int) -> int {
    lo, hi := 0, len(pt.line_segs)
    for lo < hi {
        mid := (lo + hi) / 2
        if pt.line_segs[mid].first <= line {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo - 1
}

// The index of the first segment starting at or after `line`, valid as an insertion point.
@(private = "file")
seg_bound :: proc(pt: ^Piece_Table, line: int) -> int {
    for s, i in pt.line_segs {
        if s.first >= line {
            return i
        }
    }
    return len(pt.line_segs)
}

// Make `line` a segment boundary, splitting the segment that straddles it. A no-op when it is
// one already, which is why typing at one place stops adding segments after the first key.
@(private = "file")
seg_split :: proc(pt: ^Piece_Table, line: int) {
    i := seg_at_line(pt, line)
    if i < 0 {
        return
    }
    s := pt.line_segs[i]
    if line <= s.first || line >= s.first + s.n {
        return // already a boundary, or past the end
    }
    take := line - s.first
    pt.line_segs[i].n = take
    inject_at(&pt.line_segs, i + 1, Line_Seg{line, s.at + take, s.n - take, s.delta})
}

// Resolve every line into one fresh segment, which also drops the pool's garbage. O(lines),
// amortised over PT_COMPACT_SEGS edits, and the same bargain pt_compact makes for pieces.
@(private = "file")
lines_compact :: proc(pt: ^Piece_Table) {
    flat := make([]int, pt.line_count)
    defer delete(flat)
    at := 0
    for s in pt.line_segs {
        for k in 0 ..< s.n {
            flat[at] = pt.line_store[s.at + k] + s.delta
            at += 1
        }
    }
    lines_reset(pt, flat)
}

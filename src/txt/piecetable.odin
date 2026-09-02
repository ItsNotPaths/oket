package txt

import "core:slice"
import "../rc"

// The byte storage under Doc: an ordered list of Pieces, each naming a span of one immutable
// block. Reading walks the pieces, editing splices the list; nothing already written is ever
// copied or moved, which buys two things:
//   - parsing needs no flat copy — tree-sitter's read callback is handed a piece's span
//   - a snapshot is cheap — it clones only `pieces` and `segs`, both bounded below
//
// Block 0 is the file as loaded; every later block is an append chunk. Blocks are only ever
// discarded together, with the arena that holds them.
//
// Invariants, held by every op:
//   - pieces are in document order, none empty, and `doc_off` is the running byte total
//   - the line index resolves ascending, line 0 starts at 0, and is never empty (an empty
//     document is one empty line)
//   - `size` is the sum of the piece lengths

// Every buffer this document's bytes and line starts have ever lived in. Nothing here is
// freed until the whole arena is, and that is the point: appending past the end of a buffer
// allocates a bigger one and RETIRES the old rather than releasing it, so a slice a reader
// took stays valid and keeps holding the values it held. Growth is geometric, so what is kept
// comes to about one live array; pt_compact reclaims the lot.
//
// A reader is therefore safe on two counts. Bytes and starts already written are never
// rewritten, only added past — and the arrays holding them never move.
//
// Only pt_load and pt_compact discard an arena, and both build a fresh one rather than clear
// this one, so a reader still holding the old one keeps reading it. Refcounted, and the count
// is atomic because the last release may come from an I/O worker (§9), not the main thread.
Arena :: struct {
    rc:     int,
    owned:  [dynamic][]u8, // every text block, for freeing; writer-only, so it may move freely
    spines: [dynamic][][]u8, // block-list buffers, live one last
    starts: [dynamic][]int, // line-start buffers, live one last
}

// The readable state of a document: the piece list, the line index, and the arena memory both
// point into. A Piece_Table edits its own; a Snapshot freezes a copy. Every read below takes a
// ^Text, so the two get one implementation and not two.
//
// `blocks` and `starts` are plain slices of arena buffers, not dynamic arrays, because a
// reader holds its own copy of the header. The writer's copy grows; the reader's keeps naming
// the prefix it was handed.
Text :: struct {
    arena:  ^Arena,
    blocks: [][]u8, // block 0 is the file as loaded; the rest are append chunks
    starts: []int, // the line index's pool (see Line_Seg)
    pieces: [dynamic]Piece,
    segs:   [dynamic]Line_Seg,
    size:   int,
    lines:  int,
}

Piece_Table :: struct {
    using text: Text,
    tail:       int, // the block appends go into, -1 before the first
    tail_used:  int, // bytes of it already written
}

// A run of consecutive lines whose starts sit at `starts[at ..< at+n]`, each read back
// with `delta` added. An edit pushes and re-deltas segments; it never rewrites the starts.
//
// This is RAD Debugger's TXT_LineMapRangeNode (src/text/text.h), which holds an unshifted
// ranges array plus a signed delta applied at lookup. The flat array of absolute offsets it
// replaces cost one add per line AFTER the caret on every keystroke, which is O(document) on
// the frame path — the one thing §9 says must never scale with the file.
//
// `first` is the line number of `starts[at]`, so a lookup binary-searches segments and then
// binary-searches inside one. Typing at a point splits a segment once and then only bumps
// deltas, so a run of keystrokes adds one segment and not one per key.
Line_Seg :: struct {
    first: int,
    at:    int,
    n:     int,
    delta: int,
}

// Segments accumulate on scattered editing; past this the index is flattened back to one and
// the cost is amortised the way pt_compact's is. The starts it flattened over stay in the
// arena as garbage, which is what PT_ARENA_SLACK below watches.
PT_COMPACT_SEGS :: 2048

// [off, off+len) of blocks[block], sitting at [doc_off, doc_off+len) of the document.
// `doc_off` is what makes an offset resolvable by binary search, so every op that changes a
// piece's length repairs the pieces after it.
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
// never called from the edit path, so crossing it costs nothing until a save or a drain.
PT_COMPACT_PIECES :: 2048

// How far the starts pool may outgrow the live line index before a fresh arena is worth it.
// Nothing is freed inside an arena, so every lines_compact leaves its old starts behind; this
// is the point where reclaiming them beats holding them.
PT_ARENA_SLACK :: 4

// Below this a document's garbage is not worth an arena copy, whatever the ratio says.
PT_ARENA_FLOOR :: 4096

// --- the arena ---

arena_new :: proc() -> ^Arena {
    a := new(Arena)
    a.rc = 1
    return a
}

arena_retain :: proc(a: ^Arena) {
    rc.retain(&a.rc)
}

arena_release :: proc(a: ^Arena) {
    if !rc.release(&a.rc) {
        return
    }
    for b in a.owned {
        delete(b)
    }
    for s in a.spines {
        delete(s)
    }
    for s in a.starts {
        delete(s)
    }
    delete(a.owned)
    delete(a.spines)
    delete(a.starts)
    free(a)
}

// Room in an arena buffer for `extra` more, without disturbing a slice already handed out. A
// full buffer is retired rather than freed and a bigger one takes over, so the reader's
// `live` goes on naming valid memory with the same values in it.
@(private = "file")
grown :: proc(bufs: ^[dynamic][]$T, live: []T, extra: int) -> []T {
    if len(bufs) > 0 && len(live) + extra <= len(bufs[len(bufs) - 1]) {
        return bufs[len(bufs) - 1]
    }
    next := make([]T, max(2 * (len(live) + extra), 16))
    copy(next, live)
    append(bufs, next)
    return next
}

// The arena takes ownership of the bytes. `owned` is what frees them: the block list is a
// reader-visible slice and its retired buffers hold the same pointers, so freeing from there
// would double-free.
@(private = "file")
push_block :: proc(pt: ^Piece_Table, b: []u8) {
    append(&pt.arena.owned, b)
    buf := grown(&pt.arena.spines, pt.blocks, 1)
    buf[len(pt.blocks)] = b
    pt.blocks = buf[:len(pt.blocks) + 1]
}

@(private = "file")
push_starts :: proc(pt: ^Piece_Table, vals: ..int) {
    buf := grown(&pt.arena.starts, pt.starts, len(vals))
    copy(buf[len(pt.starts):], vals)
    pt.starts = buf[:len(pt.starts) + len(vals)]
}

// --- lifecycle ---

pt_init :: proc(pt: ^Piece_Table) {
    pt.arena = arena_new()
    pt.tail = -1
    lines_set(pt, {0}) // the empty document is one empty line
}

pt_destroy :: proc(pt: ^Piece_Table) {
    arena_release(pt.arena)
    delete(pt.pieces)
    delete(pt.segs)
    pt^ = {}
}

// The bytes are cloned into block 0 of a fresh arena, so a load leaves the table as compact as
// it can be and a snapshot of the old content goes on reading it.
pt_load :: proc(pt: ^Piece_Table, src: []u8) {
    pt_renew(pt)
    pt.size = len(src)
    push_block(pt, slice.clone(src))
    if len(src) > 0 {
        append(&pt.pieces, Piece{block = 0, off = 0, len = len(src), doc_off = 0})
    }
    lines_set(pt, {0})
    for c, i in src {
        if c == '\n' {
            lines_push(pt, i + 1)
        }
    }
}

// --- reading --- Each of these takes a ^Text, so a live Piece_Table and a frozen Snapshot
// read through the same code. Odin converts either pointer implicitly.

// The invariants at the top of this file, as far as O(1) reaches (§10). Every op that changes a
// piece's length repairs the pieces after it, so the last piece's end IS the size: one read
// covers both the running total and the sum. A snapshot answers this too, because it is a Text.
text_check :: proc(t: ^Text) -> bool {
    if t.lines < 1 || len(t.segs) < 1 {
        return false
    }
    if n := len(t.pieces); n > 0 {
        return t.pieces[n - 1].doc_off + t.pieces[n - 1].len == t.size
    }
    return t.size == 0
}

text_line_count :: proc(t: ^Text) -> int {
    return t.lines
}

// The byte the line begins at. Every read of the index goes through here, which is what let
// the representation underneath change without a caller noticing.
text_line_start :: proc(t: ^Text, line: int) -> int {
    i := seg_at_line(t, line)
    if i < 0 {
        return 0
    }
    s := t.segs[i]
    return t.starts[s.at + clamp(line - s.first, 0, s.n - 1)] + s.delta
}

// Excluding the terminating newline, so no caller has to trim one. Assumes a real line index.
text_line_range :: proc(t: ^Text, line: int) -> (lo, hi: int) {
    lo = text_line_start(t, line)
    if line + 1 < t.lines {
        return lo, text_line_start(t, line + 1) - 1 // one back off the next start: the '\n'
    }
    return lo, t.size
}

text_line_len :: proc(t: ^Text, line: int) -> int {
    lo, hi := text_line_range(t, line)
    return hi - lo
}

// The largest line whose start is at or before `off`. Clamped, so an offset past the end
// answers the last line.
text_line_at_off :: proc(t: ^Text, off: int) -> int {
    lo, hi := 0, t.lines
    for lo < hi {
        mid := (lo + hi) / 2
        if text_line_start(t, mid) <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return max(0, lo - 1)
}

// As much of the document from `off` as lives in one piece — all tree-sitter's read callback
// wants, and usually a whole line. Borrowed from the arena: valid for a Snapshot's whole life,
// and for a Piece_Table only until the next edit.
text_span :: proc(t: ^Text, off: int) -> []u8 {
    i := piece_at(t.pieces[:], off)
    if i < 0 {
        return nil
    }
    p := t.pieces[i]
    return t.blocks[p.block][p.off + off - p.doc_off:p.off + p.len]
}

// The only read that costs a copy; prefer text_span or text_line where a borrow will do.
text_read :: proc(t: ^Text, lo, hi: int, alloc := context.allocator) -> []u8 {
    a := clamp(lo, 0, t.size)
    b := clamp(hi, a, t.size)
    out := make([]u8, b - a, alloc)
    n := 0
    for n < len(out) {
        src := text_span(t, a + n)
        if len(src) == 0 {
            break // a truncated span would otherwise spin
        }
        n += copy(out[n:], src)
    }
    return out
}

// Borrowed out of the arena when the line sits inside one piece — the common case, and free —
// and copied into `alloc` only when an edit has split it.
text_line :: proc(t: ^Text, line: int, alloc := context.allocator) -> []u8 {
    lo, hi := text_line_range(t, line)
    if hi <= lo {
        return nil
    }
    if s := text_span(t, lo); len(s) >= hi - lo {
        return s[:hi - lo]
    }
    return text_read(t, lo, hi, alloc)
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

// Asked by doc_maintain, never by an edit. Two things grow:
// scattered edits split pieces, and every line-index flatten leaves its old starts behind in
// the arena, which only a fresh arena reclaims.
pt_should_compact :: proc(pt: ^Piece_Table) -> bool {
    if len(pt.pieces) > PT_COMPACT_PIECES {
        return true
    }
    return len(pt.starts) > PT_ARENA_SLACK * max(pt.lines, PT_ARENA_FLOOR)
}

// Flatten to a single block and a single line segment in a FRESH arena, dropping the old one's
// spent blocks and index garbage with our reference to it. A snapshot holding that arena keeps
// it alive and reads on; the document it sees is byte-for-byte this one, since compaction moves
// bytes between blocks and never within the document.
pt_compact :: proc(pt: ^Piece_Table) {
    // Both reads run against the old arena, so both happen before pt_renew swaps it out.
    flat := text_read(pt, 0, pt.size)
    starts := make([]int, pt.lines)
    defer delete(starts)
    for i in 0 ..< pt.lines {
        starts[i] = text_line_start(pt, i)
    }

    size := pt.size
    pt_renew(pt)
    pt.size = size
    push_block(pt, flat)
    if len(flat) > 0 {
        append(&pt.pieces, Piece{block = 0, off = 0, len = len(flat), doc_off = 0})
    }
    lines_set(pt, starts)
}

// --- internals ---

// Swap in an empty arena and drop our reference to the old one. The caller refills the piece
// list and the line index; nothing survives across this.
@(private = "file")
pt_renew :: proc(pt: ^Piece_Table) {
    arena_release(pt.arena)
    pt.arena = arena_new()
    pt.blocks, pt.starts = nil, nil
    clear(&pt.pieces)
    clear(&pt.segs)
    pt.tail, pt.tail_used, pt.size, pt.lines = -1, 0, 0, 0
}

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
// nothing else was written into the chunk since. The bytes land past `tail_used`, which no
// snapshot's pieces reach, so this stays an append as far as any reader is concerned.
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

// A chunk is never grown or moved once written, since a snapshot may be reading it, so text
// that will not fit opens a fresh one sized to the text. One append is always one contiguous
// span.
@(private = "file")
pt_append :: proc(pt: ^Piece_Table, text: []u8) -> (block, off: int) {
    if pt.tail < 0 || pt.tail_used + len(text) > len(pt.blocks[pt.tail]) {
        push_block(pt, make([]u8, max(PT_CHUNK, len(text))))
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
    first := text_line_at_off(pt, a)
    last := text_line_at_off(pt, b)

    // The lines the replacement itself introduces. Their starts are absolute already, so they
    // go into the pool with a zero delta and never move again.
    at := len(pt.starts)
    n := 0
    for c, i in text {
        if c == '\n' {
            push_starts(pt, a + i + 1)
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
            pt.segs[lo] = fresh
            remove_range(&pt.segs, lo + 1, hi)
        } else {
            inject_at(&pt.segs, lo, fresh)
        }
        lo += 1
    } else if hi > lo {
        remove_range(&pt.segs, lo, hi)
    }

    // The whole point: everything after the splice is re-based by one add per SEGMENT, not one
    // per line. A run of keystrokes at one place lands here with the boundary already cut, so
    // it adds no segment at all and this loop is the only work it does.
    line := first + 1 + n
    for i in lo ..< len(pt.segs) {
        pt.segs[i].first = line
        pt.segs[i].delta += delta
        line += pt.segs[i].n
    }
    pt.lines = line
    if len(pt.segs) > PT_COMPACT_SEGS {
        lines_compact(pt)
    }
}

// --- the line index ---

// One segment over starts freshly appended to the pool. The pool is append-only, so whatever
// was there stays put and a snapshot holding it is untouched; pt_compact is what reclaims it.
@(private = "file")
lines_set :: proc(pt: ^Piece_Table, starts: []int) {
    at := len(pt.starts)
    push_starts(pt, ..starts)
    clear(&pt.segs)
    append(&pt.segs, Line_Seg{0, at, len(starts), 0})
    pt.lines = len(starts)
}

// Only valid while the last segment runs to the end of the pool, which is true during a load.
@(private = "file")
lines_push :: proc(pt: ^Piece_Table, start: int) {
    push_starts(pt, start)
    pt.segs[len(pt.segs) - 1].n += 1
    pt.lines += 1
}

// The segment holding `line`, by binary search on `first`. -1 only for an empty index.
@(private = "file")
seg_at_line :: proc(t: ^Text, line: int) -> int {
    lo, hi := 0, len(t.segs)
    for lo < hi {
        mid := (lo + hi) / 2
        if t.segs[mid].first <= line {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo - 1
}

// The index of the first segment starting at or after `line`, valid as an insertion point.
@(private = "file")
seg_bound :: proc(t: ^Text, line: int) -> int {
    for s, i in t.segs {
        if s.first >= line {
            return i
        }
    }
    return len(t.segs)
}

// Make `line` a segment boundary, splitting the segment that straddles it. A no-op when it is
// one already, which is why typing at one place stops adding segments after the first key.
@(private = "file")
seg_split :: proc(t: ^Text, line: int) {
    i := seg_at_line(t, line)
    if i < 0 {
        return
    }
    s := t.segs[i]
    if line <= s.first || line >= s.first + s.n {
        return // already a boundary, or past the end
    }
    take := line - s.first
    t.segs[i].n = take
    inject_at(&t.segs, i + 1, Line_Seg{line, s.at + take, s.n - take, s.delta})
}

// Resolve every line into one fresh segment. The starts it flattened over become arena garbage
// rather than being freed — the price of the read path having no lock — and pt_should_compact
// watches the total. O(lines), amortised over PT_COMPACT_SEGS edits.
@(private = "file")
lines_compact :: proc(pt: ^Piece_Table) {
    flat := make([]int, pt.lines)
    defer delete(flat)
    at := 0
    for s in pt.segs {
        for k in 0 ..< s.n {
            flat[at] = pt.starts[s.at + k] + s.delta
            at += 1
        }
    }
    lines_set(pt, flat)
}

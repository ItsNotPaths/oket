package txt

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// The shared multi-cursor editing core under the command line and the editor buffer: a
// Piece_Table plus a list of Cursors. Single-cursor is N == 1. Pure — no rendering, no GL.
//
// A Pos is a line and a BYTE column, matching the storage and tree-sitter's Point, so nothing on
// the edit or parse path converts. The painter's cell grid is a different thing, and doc_cells /
// doc_cell_col are the only bridge. doc_clamp_pos is the one gate guaranteeing a column lands on
// a rune boundary, and every Pos built from arithmetic passes through it.
//
// Invariants: >= 1 line, >= 1 cursor, every cursor named. `primary` is the cursor driving
// scroll-follow and the gutter, and it is an INDEX of a caret that has a name: an edit or a
// merge rebuilds the set, and the index is recovered from the name rather than falling back to
// the topmost (VIEWS.md §12). What the SET guarantees is cursor.odin's.
Doc :: struct {
    // At the head, and checked after every plugin dispatch (§10). A wild store from a plugin
    // walking a snapshot lands near a document's header more often than anywhere else, and a
    // word that can only ever be one value is what turns that into a named plugin instead of a
    // mystery four frames later. doc_check is the whole of what it costs.
    magic:   u64,
    pt:      Piece_Table,
    cursors: [dynamic]Cursor,
    primary: int,
    // Hands out cursor names (cursor.odin). Never reused inside a document, so a name that is
    // gone stays gone rather than coming back as somebody else's caret.
    next_id: u32,
    undo:    Undo, // patch journal (undo.odin)
    // Bumped on every content change. A reader keeps the generation it read and a write
    // carries it back, so a write against a document that has moved is caught rather than
    // silently landing on text its author never saw (§6).
    gen:     u64,
    // The current generation frozen, built on demand and dropped by the next change. One
    // reference is the Doc's; every caller of doc_snapshot gets its own on top.
    snap:    ^Snapshot,
    // The change log, in apply order. Several readers follow it (Doc_Reader), so it is not
    // drained by the first: each keeps a sequence number and the log drops what all have passed.
    changes:      [dynamic]Doc_Change,
    changes_base: u64, // sequence number of changes[0]
    changes_next: u64, // one past the last recorded
    seen:         [Doc_Reader]u64, // how far each reader has got
    sink:         Doc_Sink, // nil write = not journaled
}

// An optional tap on the edit funnel, offered every splice at apply time with the text still
// in hand (§10's recovery journal is the only user). txt stays pure: it hands over bytes and
// does not know what becomes of them. The change log above cannot serve this, because its
// offsets are pre-splice and carry no text.
Doc_Sink :: struct {
    user:  rawptr,
    write: proc(user: rawptr, at, old_len: int, text: string),
}

// Fixed rather than a registration list: three of them, all living as long as the Doc.
Doc_Reader :: enum {
    Highlight, // folds each change into the cached parse tree (highlight.odin)
    Folds,     // shifts collapsed ranges so an edit elsewhere does not drop them (src/edit)
    Fields,    // carries the descriptor's spans along with the text (src/store/fields.odin)
}

// Both byte offsets and points, because tree-sitter's Input_Edit wants both. Offsets are in the
// document as it stood when the change was applied, so a reader must replay the list in order.
Doc_Change :: struct {
    start, old_end, new_end:          int,
    start_pt, old_end_pt, new_end_pt: Pos,
}

// How far the log may run ahead of its slowest reader. Past it the log is dropped and everyone
// behind is told they lost it — a rebuild costs less than an unbounded list. Measured between
// commits: one commit is atomic in the log whatever its size (doc_record_changes).
DOC_CHANGE_MAX :: 256

Pos :: struct {
    line: int,
    col:  int, // BYTES into the line
}

// --- lifecycle ---

DOC_MAGIC :: 0x6f6b_6574_646f_6300 // "oketdoc\0"

doc_init :: proc(d: ^Doc) {
    d.magic = DOC_MAGIC
    pt_init(&d.pt)
    append(&d.cursors, new_cursor(d, {}, {}))
}

// The invariants worth checking after every plugin dispatch (§10). All O(1), so leaving them on
// in release costs nothing measurable, and each arm names a corruption that is otherwise silent.
// The storage answers for its own (text_check); this adds the ones a Doc has on top.
doc_check :: proc(d: ^Doc) -> bool {
    if d.magic != DOC_MAGIC || d.primary < 0 || d.primary >= len(d.cursors) {
        return false
    }
    return text_check(&d.pt)
}

doc_destroy :: proc(d: ^Doc) {
    doc_drop_snap(d)
    pt_destroy(&d.pt)
    delete(d.cursors)
    delete(d.changes)
    undo_destroy(d)
}

// Replaces all content, collapses to one cursor at the origin, and discards undo history. CRLF
// collapses to LF and one trailing newline is dropped — Buffer puts it back on save.
doc_set_text :: proc(d: ^Doc, text: string) {
    undo_destroy(d)
    pt_load(&d.pt, doc_normalize(text))
    doc_reset_cursor(d, {})
    // Nothing can track a wholesale replacement, so every reader rebuilds from scratch.
    doc_changes_reset(d)
    doc_bump(d)
}

doc_clear :: proc(d: ^Doc) {
    doc_set_text(d, "")
}

// --- reading ---

// The document as it stands, for anyone who reads off the edit path: a worker, or a plugin
// between dispatches (§6). Cached per generation, so a frame that asks twice pays once. The
// caller owns the returned reference and releases it.
doc_snapshot :: proc(d: ^Doc) -> ^Snapshot {
    if d.snap == nil {
        d.snap = snapshot_take(&d.pt, d.gen)
    }
    snapshot_retain(d.snap)
    return d.snap
}

// Flatten the table once scattered editing has splintered it. The save path and the frame
// drain both call this; neither decides when, so the threshold lives in one place.
//
// Content and generation come through untouched, which is exactly why the cached snapshot has
// to go: it points into the arena compaction just spent, and would pin that garbage for as
// long as the document idles.
doc_maintain :: proc(d: ^Doc) {
    if !pt_should_compact(&d.pt) {
        return
    }
    pt_compact(&d.pt)
    doc_drop_snap(d)
}

doc_len :: proc(d: ^Doc) -> int {
    return d.pt.size
}

doc_line_count :: proc(d: ^Doc) -> int {
    return text_line_count(&d.pt)
}

doc_line_len :: proc(d: ^Doc, line: int) -> int {
    return text_line_len(&d.pt, line)
}

// Without the newline. Borrowed from the piece table when the line is one piece, copied into
// `alloc` when an edit split it. Read only, and dead after the next edit.
doc_line :: proc(d: ^Doc, line: int, alloc := context.temp_allocator) -> []u8 {
    return text_line(&d.pt, line, alloc)
}

// The pair every edit crosses. Both clamp.
doc_off :: proc(d: ^Doc, p: Pos) -> int {
    return text_off(&d.pt, p)
}

doc_pos :: proc(d: ^Doc, off: int) -> Pos {
    return text_pos(&d.pt, off)
}

doc_string :: proc(d: ^Doc, allocator := context.allocator) -> string {
    return string(text_read(&d.pt, 0, d.pt.size, allocator))
}

// One position through one splice, which is the whole of the .Shift policy and of how a
// descriptor's fields ride the text (store/fields.odin). Replay a change list in the order it
// was recorded and a point comes out where the text under it went.
//
// `low` is the left edge of a span and the only asymmetry: text inserted exactly at it belongs
// to the span, so a low edge stays put where a high edge moves. A caret is a high edge — typing
// in front of it pushes it along.
point_shift :: proc(p: Pos, ch: Doc_Change, low: bool) -> Pos {
    s, o, n := ch.start_pt, ch.old_end_pt, ch.new_end_pt
    if !pos_less(p, o) && (!low || pos_less(s, p)) {
        // After the splice: on the last line it replaced, the column rebases on the new end.
        if p.line == o.line {
            return {n.line, n.col + p.col - o.col}
        }
        return {p.line + n.line - o.line, p.col}
    }
    if pos_less(s, p) {
        return s // inside what the splice replaced, so it collapses onto the front of it
    }
    return p
}

// --- the cell grid --- The painter draws CELLS, one per rune; the document counts BYTES. The
// two agree until a line holds a multi-byte rune, and this is the bridge. An ASCII line costs
// one scan and no allocation.

// `offs` has one entry more than `runes`, the last being the line's byte length, so a cell range
// converts with no special case at the end. Temp-allocated: valid for the frame.
Cells :: struct {
    runes: []rune,
    offs:  []int,
}

// `limit` cells and no more, because a painter needs the columns it can show and not the ones
// it cannot: a 16 KB minified line laid out in full to fill 200 columns is 80x the work on the
// frame path. Callers that genuinely want the whole line leave it at the default.
doc_cells :: proc(
    d: ^Doc,
    line: int,
    limit := max(int),
    alloc := context.temp_allocator,
) -> Cells {
    src := doc_line(d, line, alloc)
    cap_hint := min(len(src), limit)
    rs := make([dynamic]rune, 0, cap_hint, alloc)
    offs := make([dynamic]int, 0, cap_hint + 1, alloc)
    end := 0
    for i := 0; i < len(src) && len(rs) < limit; {
        r, sz := utf8.decode_rune(src[i:])
        append(&rs, r)
        append(&offs, i)
        i += max(sz, 1)
        end = i
    }
    // offs is always one longer than runes. Where it ends is the line's end when nothing was
    // cut and the last decoded rune's end when something was, so cells_off can never hand back
    // a byte the caller has no cell for. A limit of 0 leaves offs = {0}, which is the same rule.
    append(&offs, len(rs) < limit ? len(src) : end)
    return Cells{rs[:], offs[:]}
}

cells_count :: proc(c: Cells) -> int {
    return len(c.runes)
}

// Without building the table: the column bound and the highlighter's row ask once per drawn row
// and need no allocation for it.
doc_cell_count :: proc(d: ^Doc, line: int) -> int {
    src := doc_line(d, line)
    n := 0
    for i := 0; i < len(src); n += 1 {
        _, sz := utf8.decode_rune(src[i:])
        i += max(sz, 1)
    }
    return n
}

// The cell a byte column sits at (rounded up onto a rune boundary), and the byte column a cell
// starts at. A binary search because the highlighter asks twice per capture per row.
cells_col :: proc(c: Cells, byte_col: int) -> int {
    lo, hi := 0, len(c.offs)
    for lo < hi {
        mid := (lo + hi) / 2
        if c.offs[mid] < byte_col {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return min(lo, len(c.runes))
}

cells_off :: proc(c: Cells, cell: int) -> int {
    return c.offs[clamp(cell, 0, len(c.runes))]
}

// The two conversions that do not need the whole table, so they walk instead of building one.
doc_cell_col :: proc(d: ^Doc, p: Pos) -> int {
    src := doc_line(d, p.line)
    n := 0
    for i := 0; i < min(p.col, len(src)); n += 1 {
        _, sz := utf8.decode_rune(src[i:])
        i += max(sz, 1)
    }
    return n
}

doc_byte_col :: proc(d: ^Doc, line, cell: int) -> int {
    src := doc_line(d, line)
    i, n := 0, 0
    for i < len(src) && n < cell {
        _, sz := utf8.decode_rune(src[i:])
        i += max(sz, 1)
        n += 1
    }
    return i
}

// Onto a real line, a real column, and a rune boundary. The one gate every derived Pos passes
// through: a column landing mid-rune would split a character on the next edit.
doc_clamp_pos :: proc(d: ^Doc, p: Pos) -> Pos {
    return text_clamp_pos(&d.pt, p)
}

// --- editing --- Every edit funnels through doc_apply: non-overlapping replacements, one per
// cursor, applied back-to-front so the earlier ones keep valid offsets.

doc_insert_rune :: proc(d: ^Doc, r: rune) -> bool {
    return doc_insert_text(d, utf8.runes_to_string({r}, context.temp_allocator))
}

// `text` may contain '\n'. Shared by typing, indent, newline and paste.
doc_insert_text :: proc(d: ^Doc, text: string) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in edit_cursors(d) {
        lo, hi := cursor_range(c)
        append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), text, 0, c.id})
    }
    return doc_commit(d, edits[:])
}

doc_newline :: proc(d: ^Doc) -> bool {
    return doc_insert_text(d, "\n")
}

// --- clipboard (GLFW I/O lives in input.odin) ---

// Newlines are stored bytes, so a span across lines carries them already.
doc_text :: proc(d: ^Doc, lo, hi: Pos, alloc := context.allocator) -> string {
    return string(text_read(&d.pt, doc_off(d, lo), doc_off(d, hi), alloc))
}

// Each cursor's selection, or with nothing selected each cursor's whole line plus a newline.
// `pieces` is an exact-length clone, because the caller frees it with `delete`.
doc_copy :: proc(d: ^Doc, alloc := context.allocator) -> (joined: string, pieces: []string) {
    order := cursor_order(d, context.temp_allocator)
    any_sel := doc_any_selection(d)
    out := make([dynamic]string, 0, len(order), context.temp_allocator)
    for idx in order {
        c := d.cursors[idx]
        if any_sel {
            if !cursor_has_selection(c) {
                continue
            }
            lo, hi := cursor_range(c)
            append(&out, doc_text(d, lo, hi, alloc))
        } else {
            line := c.head.line
            content := doc_text(d, Pos{line, 0}, Pos{line, doc_line_len(d, line)}, alloc)
            append(&out, strings.concatenate({content, "\n"}, alloc))
        }
    }
    sep := any_sel ? "\n" : ""
    return strings.join(out[:], sep, alloc), slice.clone(out[:], alloc)
}

// A plain paste: the same text at every cursor, replacing selections.
doc_paste :: proc(d: ^Doc, text: string) -> bool {
    return doc_insert_text(d, text)
}

// One piece per cursor in document order. Caller guarantees len(pieces) == cursor count.
doc_paste_pieces :: proc(d: ^Doc, pieces: []string) -> bool {
    order := cursor_order(d, context.temp_allocator)
    edits := make([dynamic]Edit, 0, len(order), context.temp_allocator)
    for idx, k in order {
        c := d.cursors[idx]
        lo, hi := cursor_range(c)
        append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), pieces[k], 0, c.id})
    }
    return doc_commit(d, edits[:])
}

// What a kill takes, before it is taken. The kill itself is doc_copy then doc_cut, so a killed
// range reaches the clipboard by the path a copied one does.
Kill :: enum {
    To_Line_End,
    Whole_Line,
    To_Line_Start,
}

// At the end of a line To_Line_End takes the line break, so repeated kills join lines rather
// than stopping on an empty selection that doc_cut would read as "no selection, take the line".
doc_select_kill :: proc(d: ^Doc, k: Kill) {
    spans := make([dynamic][2]Pos, 0, len(d.cursors), context.temp_allocator)
    last := doc_line_count(d) - 1
    for c in d.cursors {
        line := c.head.line
        eol := Pos{line, doc_line_len(d, line)}
        lo, hi: Pos
        switch k {
        case .To_Line_End:
            lo, hi = c.head, eol
            if c.head == eol && line < last {
                hi = Pos{line + 1, 0}
            }
        case .Whole_Line:
            lo = Pos{line, 0}
            hi = line < last ? Pos{line + 1, 0} : eol
        case .To_Line_Start:
            lo, hi = Pos{line, 0}, c.head
        }
        append(&spans, [2]Pos{lo, hi})
    }
    doc_set_spans(d, spans[:])
}

// Each cursor's selection, or its whole line when nothing is selected. Pair with doc_copy, and
// the pairing is the reason for `any_sel`: a mixed set copies only the selections, so cutting a
// bare caret's line beside them would delete text that never reached the clipboard.
doc_cut :: proc(d: ^Doc) -> bool {
    any_sel := doc_any_selection(d)
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in edit_cursors(d) {
        if any_sel && !cursor_has_selection(c) {
            continue
        }
        lo, hi := cursor_range(c)
        if !cursor_has_selection(c) {
            line := c.head.line
            lo = Pos{line, 0}
            hi = line < doc_line_count(d) - 1 ? Pos{line + 1, 0} : Pos{line, doc_line_len(d, line)}
        }
        append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0, c.id})
    }
    return doc_commit(d, edits[:])
}

// 0 at end of line. The twin below reads the rune BEFORE p, with the size to step back over it.
doc_rune_at :: proc(d: ^Doc, p: Pos) -> rune {
    src := doc_line(d, p.line)
    if p.col >= len(src) {
        return 0
    }
    r, _ := utf8.decode_rune(src[p.col:])
    return r
}

doc_rune_before :: proc(d: ^Doc, p: Pos) -> (r: rune, size: int) {
    src := doc_line(d, p.line)
    if p.col <= 0 {
        return 0, 0
    }
    r, size = utf8.decode_last_rune(src[:min(p.col, len(src))])
    return r, max(size, 1)
}

// The selection, else the rune to the left, else join with the previous line.
doc_backspace :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in edit_cursors(d) {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0, c.id})
        } else if c.head.col > 0 {
            prev, size := doc_rune_before(d, c.head)
            at := Pos{c.head.line, c.head.col - size}
            // Inside an empty auto-pair "()" both halves go.
            if close, ok := pair_close(prev); ok && doc_rune_at(d, c.head) == close {
                _, csz := utf8.encode_rune(close)
                append(&edits, Edit{doc_off(d, at), doc_off(d, c.head) + csz, "", 0, c.id})
            } else {
                append(&edits, Edit{doc_off(d, at), doc_off(d, c.head), "", 0, c.id})
            }
        } else if c.head.line > 0 {
            eol := Pos{c.head.line - 1, doc_line_len(d, c.head.line - 1)}
            append(&edits, Edit{doc_off(d, eol), doc_off(d, c.head), "", 0, c.id})
        }
    }
    return doc_commit(d, edits[:])
}

// The selection, else the rune to the right, else pull the next line up.
doc_delete :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in edit_cursors(d) {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0, c.id})
        } else if c.head.col < doc_line_len(d, c.head.line) {
            _, size := utf8.decode_rune(doc_line(d, c.head.line)[c.head.col:])
            append(&edits, Edit{doc_off(d, c.head), doc_off(d, c.head) + max(size, 1), "", 0, c.id})
        } else if c.head.line < doc_line_count(d) - 1 {
            next := Pos{c.head.line + 1, 0}
            append(&edits, Edit{doc_off(d, c.head), doc_off(d, next), "", 0, c.id})
        }
    }
    return doc_commit(d, edits[:])
}

// Delete the word to the left, or join with the previous line at column 0.
doc_delete_word_back :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in edit_cursors(d) {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0, c.id})
        } else if c.head.col > 0 {
            to := word_left_index(doc_line(d, c.head.line), c.head.col)
            append(&edits, Edit{doc_off(d, Pos{c.head.line, to}), doc_off(d, c.head), "", 0, c.id})
        } else if c.head.line > 0 {
            eol := Pos{c.head.line - 1, doc_line_len(d, c.head.line - 1)}
            append(&edits, Edit{doc_off(d, eol), doc_off(d, c.head), "", 0, c.id})
        }
    }
    return doc_commit(d, edits[:])
}

// Delete the word to the right, or pull the next line up at end of line.
doc_delete_word_forward :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in edit_cursors(d) {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0, c.id})
        } else if c.head.col < doc_line_len(d, c.head.line) {
            to := word_right_index(doc_line(d, c.head.line), c.head.col)
            append(&edits, Edit{doc_off(d, c.head), doc_off(d, Pos{c.head.line, to}), "", 0, c.id})
        } else if c.head.line < doc_line_count(d) - 1 {
            next := Pos{c.head.line + 1, 0}
            append(&edits, Edit{doc_off(d, c.head), doc_off(d, next), "", 0, c.id})
        }
    }
    return doc_commit(d, edits[:])
}

// --- internals ---

// The one place the generation moves. Dropping the cached snapshot here is what keeps a
// holder's copy honest: it goes on reading the generation it asked for, and the next asker
// gets a fresh one.
@(private = "file")
doc_bump :: proc(d: ^Doc) {
    d.gen += 1
    doc_drop_snap(d)
}

@(private = "file")
doc_drop_snap :: proc(d: ^Doc) {
    if d.snap != nil {
        snapshot_release(d.snap)
        d.snap = nil
    }
}

// The bytes in [lo, hi) become `text`. caret_delta nudges the resulting caret left of the
// inserted text's end, in bytes and on that line only: 1 lands inside a fresh ASCII pair, -1
// steps one past an existing close, 0 for ordinary edits.
Edit :: struct {
    lo, hi:      int,
    text:        string,
    caret_delta: int,
    // The caret that asked for this edit, carried onto the one that replaces it under .Follow
    // (CURSORS.md §5). 0 is nobody asking, and the replacement is named fresh.
    id:          u32,
}

@(private = "file")
edit_is_noop :: proc(e: Edit) -> bool {
    return e.lo == e.hi && len(e.text) == 0
}

// One pass for the whole batch, then `cur` says where the carets go. Every offset here is
// stated against the document as it arrived, and the piece table takes them all together, so
// nothing has to stay true while the bytes underneath it move. Non-nil `rec` collects
// reversible patches for the undo journal. `edits_in` is read only.
doc_apply :: proc(d: ^Doc, edits_in: []Edit, rec: ^Batch = nil, cur := Commit{}) -> bool {
    if len(edits_in) == 0 {
        // A cursor-only commit (CURSORS.md §3): the set lands, the generation does not move.
        if cur.policy == .Set {
            doc_set_cursors(d, cur.set, cur.primary)
            doc_merge_cursors(d)
        }
        return false
    }
    prim := d.cursors[d.primary].id // the name .Follow gives the set back, past the sort below
    edits := slice.clone(edits_in, context.temp_allocator)
    slice.sort_by(edits, proc(a, b: Edit) -> bool {
        return a.lo != b.lo ? a.lo < b.lo : a.hi < b.hi
    })

    // Back-to-front only keeps the offsets valid while the ranges stay apart, and two carets
    // inside one word reach the same word start, so overlaps fuse into the union: the region is
    // replaced once, by both texts in document order. Insertions are points and never fuse.
    w := 0
    for r in 1 ..< len(edits) {
        acc, e := &edits[w], edits[r]
        if e.lo < acc.hi {
            acc.hi = max(acc.hi, e.hi)
            acc.text = strings.concatenate({acc.text, e.text}, context.temp_allocator)
            acc.caret_delta = e.caret_delta
            if e.id == prim {
                acc.id = e.id // two carets in one word leave one, and it is the primary's
            }
            continue
        }
        w += 1
        edits[w] = e
    }
    edits = edits[:w + 1]

    // Where each edit's text ends up once the batch is done: `lo` is where it was stated, and
    // the edits before it grow or shrink the text ahead of it. The cursors and the journal's
    // inverse both read the finished document, so both want this rather than `lo`.
    landed := make([]int, len(edits), context.temp_allocator)
    cum := 0
    for e, i in edits {
        landed[i] = e.lo + cum
        cum += len(e.text) - (e.hi - e.lo)
    }

    // EVERYTHING BELOW READS THE DOCUMENT AS IT STANDS — the batch lands in one pass at the
    // end, so the inserted text says where it ends rather than the document being asked after.
    changed := false
    removed := make([]string, len(edits), context.temp_allocator)
    splices := make([]Splice, len(edits), context.temp_allocator)
    for e, i in edits {
        if !edit_is_noop(e) {
            changed = true
        }
        removed[i] = string(text_read(&d.pt, e.lo, e.hi, context.temp_allocator))
        splices[i] = Splice{lo = e.lo, hi = e.hi, text = transmute([]u8)e.text}
    }

    // Back to front, which is the order both readers replay in: each entry is stated against the
    // document the ones before it have already landed on. .Shift replays `spliced` as well, and
    // the Doc's own log cannot serve it — that one is bounded and drops.
    spliced := make([dynamic]Doc_Change, 0, len(edits), context.temp_allocator)
    for i := len(edits) - 1; i >= 0; i -= 1 {
        e := edits[i]
        if edit_is_noop(e) {
            continue
        }
        start_pt := doc_pos(d, e.lo)
        append(
            &spliced,
            Doc_Change {
                start = e.lo,
                old_end = e.hi,
                new_end = e.lo + len(e.text),
                start_pt = start_pt,
                old_end_pt = doc_pos(d, e.hi),
                new_end_pt = pos_after(start_pt, e.text),
            },
        )
        if d.sink.write != nil {
            d.sink.write(d.sink.user, e.lo, e.hi - e.lo, e.text)
        }
    }

    pt_splice_many(&d.pt, splices)
    doc_record_changes(d, spliced[:])

    if rec != nil {
        for e, i in edits {
            if removed[i] == "" && e.text == "" {
                continue // no-op, e.g. backspace at the document origin
            }
            append(
                &rec.ops,
                Op {
                    at = e.lo,
                    inv_at = landed[i],
                    removed = strings.clone(removed[i]),
                    inserted = strings.clone(e.text),
                },
            )
        }
    }

    switch cur.policy {
    case .Follow:
        clear(&d.cursors)
        for e, i in edits {
            p := doc_pos(d, landed[i] + len(e.text))
            // same line, by contract
            p.col = clamp(p.col - e.caret_delta, 0, doc_line_len(d, p.line))
            q := doc_clamp_pos(d, p)
            // The caret an edit leaves IS the caret that asked for it, so scroll-follow stays
            // on the one the user is typing at instead of the topmost (VIEWS.md §12). An edit
            // nobody asked for — an undo replay, a whole-buffer write — is named fresh.
            append(&d.cursors, new_cursor(d, q, q, -1, e.id))
        }
        d.primary = cursor_index(d, prim)
        doc_merge_cursors(d)
    case .Shift:
        // The splice loop never touches the cursors, so they still hold pre-edit positions.
        for &c in d.cursors {
            for ch in spliced {
                c.anchor = point_shift(c.anchor, ch, low = false)
                c.head = point_shift(c.head, ch, low = false)
            }
            c.anchor, c.head = doc_clamp_pos(d, c.anchor), doc_clamp_pos(d, c.head)
        }
    case .Pin:
        // Clamped only: the document can be shorter than the rows the carets sit on.
        for &c in d.cursors {
            c.anchor, c.head = doc_clamp_pos(d, c.anchor), doc_clamp_pos(d, c.head)
        }
    case .Set:
        doc_set_cursors(d, cur.set, cur.primary)
        doc_merge_cursors(d) // normalization, not policy: one rule for every placed caret
    }
    if changed {
        doc_bump(d)
    }
    return changed
}

// Oldest first. `lost` means the log no longer reaches back that far, so the reader rebuilds
// from the document; the changes returned with it are valid but not the whole story.
doc_changes_since :: proc(d: ^Doc, who: Doc_Reader) -> (changes: []Doc_Change, lost: bool) {
    if d.seen[who] < d.changes_base {
        return nil, true
    }
    return d.changes[d.seen[who] - d.changes_base:], false
}

// Trims the log to the slowest reader, which keeps it short while everyone keeps up.
doc_changes_ack :: proc(d: ^Doc, who: Doc_Reader) {
    d.seen[who] = d.changes_next
    slowest := d.changes_next
    for s in d.seen {
        slowest = min(slowest, s)
    }
    if slowest > d.changes_base {
        remove_range(&d.changes, 0, int(slowest - d.changes_base))
        d.changes_base = slowest
    }
}

// Anyone behind is told they lost it; anyone caught up is untouched. That matters: a buffer with
// no grammar has a highlighter that never acks, and the fold set must not lose its ranges for it.
@(private = "file")
doc_changes_drop :: proc(d: ^Doc) {
    clear(&d.changes)
    d.changes_base = d.changes_next
}

// A wholesale load: no edit to track through, so a current reader is as out of date as any.
@(private = "file")
doc_changes_reset :: proc(d: ^Doc) {
    d.changes_next += 1 // past every reader's `seen`
    doc_changes_drop(d)
}

// A COMMIT'S CHANGES GO IN TOGETHER. Half a transaction in the log is worse than none: a
// reader would carry its spans through some of the splices under them and not the rest, and
// nothing afterwards says so. So the drop is decided once, before the batch lands, and one
// batch may run past DOC_CHANGE_MAX — the cap bounds the log BETWEEN commits (§11).
@(private = "file")
doc_record_changes :: proc(d: ^Doc, batch: []Doc_Change) {
    if len(batch) == 0 {
        return
    }
    if len(d.changes) + len(batch) > DOC_CHANGE_MAX {
        doc_changes_drop(d) // everyone behind rebuilds; the log restarts AT this batch
    }
    append(&d.changes, ..batch)
    d.changes_next += u64(len(batch))
}

// Where `text` inserted at `at` ends. The batch has not landed when this is asked, so it is
// arithmetic rather than a read of the document.
@(private = "file")
pos_after :: proc(at: Pos, text: string) -> Pos {
    nl := strings.last_index_byte(text, '\n')
    if nl < 0 {
        return {at.line, at.col + len(text)}
    }
    return {at.line + strings.count(text, "\n"), len(text) - nl - 1}
}

// CRLF collapsed to LF and one trailing newline dropped — both the load's business; Buffer puts
// the newline back on save. Temp-allocated, and returns the input untouched when there is
// nothing to strip.
@(private = "file")
doc_normalize :: proc(text: string) -> []u8 {
    if !strings.contains(text, "\r") {
        return transmute([]u8)(strings.has_suffix(text, "\n") ? text[:len(text) - 1] : text)
    }
    // CR first, then the trailing newline: a CRLF file ends "\r\n", and trimming the '\n' first
    // would leave the '\r' on the last line.
    out := make([dynamic]u8, 0, len(text), context.temp_allocator)
    for i in 0 ..< len(text) {
        if text[i] == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
            continue
        }
        append(&out, text[i])
    }
    if len(out) > 0 && out[len(out) - 1] == '\n' {
        pop(&out)
    }
    return out[:]
}

// Cursor indices in document order, for clipboard ops that need a stable left-to-right one.
@(private = "file")
Keyed_Cursor :: struct {
    lo:  Pos,
    idx: int,
}

@(private = "file")
cursor_order :: proc(d: ^Doc, alloc := context.allocator) -> []int {
    keyed := make([]Keyed_Cursor, len(d.cursors), context.temp_allocator)
    for c, i in d.cursors {
        lo, _ := cursor_range(c)
        keyed[i] = {lo, i}
    }
    slice.sort_by(keyed, proc(a, b: Keyed_Cursor) -> bool {
        return pos_less(a.lo, b.lo)
    })
    out := make([]int, len(keyed), alloc)
    for k, i in keyed {
        out[i] = k.idx
    }
    return out
}

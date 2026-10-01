package txt

import "lues:docs"
import "lues:pt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// The shared multi-cursor editing core under the command line and the editor buffer: a lues
// docs.Doc plus a list of Cursors. Single-cursor is N == 1. Pure — no rendering, no GL.
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
    // The bytes, gen, snapshot, undo and change log. A store doc's belongs to the store.
    using core: ^docs.Doc,
    owned:      bool,
    cursors:    [dynamic]Cursor,
    primary:    int,
    // Hands out cursor names (cursor.odin). Never reused inside a document, so a name that is
    // gone stays gone rather than coming back as somebody else's caret.
    next_id:    u32,
    made:       int, // undo steps ever opened; the cap trims, so not len(undo)
    readers:    [Doc_Reader]docs.Reader,
    sink:       Doc_Sink, // nil write = not journaled
}

// An optional tap on the edit funnel, offered every splice with the text still in hand (§10's
// recovery journal is the only user). Back to front, against the document before the batch.
Doc_Sink :: struct {
    user:  rawptr,
    write: proc(user: rawptr, at, old_len: int, text: string),
}

Doc_Reader :: enum {
    Highlight, // folds each change into the cached parse tree (highlight.odin)
    Folds,     // shifts collapsed ranges so an edit elsewhere does not drop them (src/edit)
    Fields,    // carries the descriptor's spans along with the text (src/store/fields.odin)
    Carets,    // carries the set through a splice for .Shift
}

Pos :: pt.Pos // col in BYTES

// --- lifecycle ---

// A store doc passes its core; without one the Doc makes and owns its own.
doc_init :: proc(d: ^Doc, core: ^docs.Doc = nil) {
    d.core = core
    if core == nil {
        d.core = new(docs.Doc)
        docs.doc_init(d.core)
        d.owned = true
    }
    for &r in d.readers {
        r = docs.reader_add(d.core)
    }
    append(&d.cursors, new_cursor(d, {}, {}))
}

// The invariants worth checking after every plugin dispatch (§10). All O(1).
doc_check :: proc(d: ^Doc) -> bool {
    return d.primary >= 0 && d.primary < len(d.cursors) && docs.doc_check(d.core)
}

doc_destroy :: proc(d: ^Doc) {
    delete(d.cursors)
    if d.owned {
        docs.doc_destroy(d.core)
        free(d.core)
    }
    d^ = {}
}

// Replaces all content, collapses to one cursor at the origin, and discards undo history. CRLF
// collapses to LF and one trailing newline is dropped — Buffer puts it back on save.
doc_set_text :: proc(d: ^Doc, text: string) {
    docs.doc_set(d.core, doc_normalize(text))
    doc_reset_cursor(d, {})
    doc_changes_ack(d, .Carets) // the others rebuild; the carets were just placed
}

doc_clear :: proc(d: ^Doc) {
    doc_set_text(d, "")
}

// --- reading ---

// The caller owns the returned reference and releases it.
doc_snapshot :: proc(d: ^Doc) -> ^pt.Snapshot {
    return docs.doc_snapshot(d.core)
}

doc_maintain :: proc(d: ^Doc) {
    docs.doc_maintain(d.core)
}

doc_len :: proc(d: ^Doc) -> int {
    return d.table.size
}

doc_line_count :: proc(d: ^Doc) -> int {
    return pt.text_line_count(&d.table)
}

doc_line_len :: proc(d: ^Doc, line: int) -> int {
    return pt.text_line_len(&d.table, line)
}

// Without the newline. Borrowed from the piece table when the line is one piece, copied into
// `alloc` when an edit split it. Read only, and dead after the next edit.
doc_line :: proc(d: ^Doc, line: int, alloc := context.temp_allocator) -> []u8 {
    return pt.text_line(&d.table, line, alloc)
}

// The pair every edit crosses. Both clamp.
doc_off :: proc(d: ^Doc, p: Pos) -> int {
    return pt.text_off(&d.table, p)
}

doc_pos :: proc(d: ^Doc, off: int) -> Pos {
    return pt.text_pos(&d.table, off)
}

doc_string :: proc(d: ^Doc, allocator := context.allocator) -> string {
    return string(pt.text_read(&d.table, 0, d.table.size, allocator))
}

// --- the cell grid --- The painter draws CELLS, one per CLUSTER (IME.md §4); the document
// counts BYTES. The two agree until a line holds a multi-byte rune or a combining mark, and
// this is the bridge. An ASCII line costs one scan and no allocation.

// `offs` has one entry more than `runes`, the last being the line's byte length, so a cell range
// converts with no special case at the end. `runes[i]` is the FIRST rune of cluster i — what an
// atlas lookup wants until §5's shaping replaces it. Temp-allocated: valid for the frame.
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
        r, _ := utf8.decode_rune(src[i:])
        append(&rs, r)
        append(&offs, i)
        i = cluster_next(src, i)
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
        i = cluster_next(src, i)
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
        i = cluster_next(src, i)
    }
    return n
}

doc_byte_col :: proc(d: ^Doc, line, cell: int) -> int {
    src := doc_line(d, line)
    i, n := 0, 0
    for i < len(src) && n < cell {
        i = cluster_next(src, i)
        n += 1
    }
    return i
}

// The DISPLAY column vertical motion aims at (IME.md §4): a tab expands to its next stop and
// every other cluster owns its base rune's columns, which is the same answer view.advance
// gives the paint. The tab width is the DESCRIPTOR'S, threaded through doc_move — never a
// constant of txt's own.
doc_goal_col :: proc(d: ^Doc, p: Pos, tab: int) -> int {
    src := doc_line(d, p.line)
    col := 0
    for i := 0; i < min(p.col, len(src)); {
        if src[i] == '\t' {
            col += tab - col % tab
            i += 1
        } else {
            col += cluster_cells(src, i)
            i = cluster_next(src, i)
        }
    }
    return col
}

// The byte the goal lands on in another line: the first boundary at or past the column, so a
// caret never splits a tab or a cluster on the way down.
doc_goal_byte :: proc(d: ^Doc, line, goal, tab: int) -> int {
    src := doc_line(d, line)
    col, i := 0, 0
    for i < len(src) && col < goal {
        if src[i] == '\t' {
            col += tab - col % tab
            i += 1
        } else {
            col += cluster_cells(src, i)
            i = cluster_next(src, i)
        }
    }
    return i
}

// Onto a real line, a real column, and a rune boundary. The one gate every derived Pos passes
// through: a column landing mid-rune would split a character on the next edit.
doc_clamp_pos :: proc(d: ^Doc, p: Pos) -> Pos {
    return pt.text_clamp_pos(&d.table, p)
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

// --- clipboard (SDL I/O lives in oket/routing.odin) ---

// Newlines are stored bytes, so a span across lines carries them already.
doc_text :: proc(d: ^Doc, lo, hi: Pos, alloc := context.allocator) -> string {
    return string(pt.text_read(&d.table, doc_off(d, lo), doc_off(d, hi), alloc))
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

@(private)
edit_is_noop :: proc(e: Edit) -> bool {
    return e.lo == e.hi && len(e.text) == 0
}

// Raw: nothing to undo, and the history goes.
doc_apply :: proc(d: ^Doc, edits: []Edit, cur := Commit{}, tab := 4) -> bool {
    return doc_land(d, edits, .Forget, cur, tab)
}

// One pass for the whole batch, then `cur` says where the carets go. Every offset is stated
// against the document as it arrived.
@(private)
doc_land :: proc(d: ^Doc, edits: []Edit, history: docs.History, cur: Commit, tab: int) -> bool {
    fused := doc_fuse(d, edits)
    gen := d.gen
    docs.doc_apply(d.core, doc_splices(fused), history)
    return doc_landed(d, fused, gen, history != .Forget, cur, tab)
}

// Clamped, sorted, and overlaps fused into their union, the rule lues's own fuse applies, so
// both agree on what lands. Unlike lues's, no-ops stay for their carets, and two carets in one
// word leave the primary's id. Temp-allocated.
doc_fuse :: proc(d: ^Doc, edits_in: []Edit) -> []Edit {
    if len(edits_in) == 0 {
        return nil
    }
    prim := d.cursors[d.primary].id
    size := d.table.size
    edits := make([]Edit, len(edits_in), context.temp_allocator)
    for e, i in edits_in {
        edits[i] = e
        edits[i].lo = clamp(e.lo, 0, size)
        edits[i].hi = clamp(e.hi, edits[i].lo, size)
    }
    slice.sort_by(edits, proc(a, b: Edit) -> bool {
        return a.lo != b.lo ? a.lo < b.lo : a.hi < b.hi
    })
    w := 0
    for r in 1 ..< len(edits) {
        acc, e := &edits[w], edits[r]
        if e.lo < acc.hi {
            acc.hi = max(acc.hi, e.hi)
            acc.text = strings.concatenate({acc.text, e.text}, context.temp_allocator)
            acc.caret_delta = e.caret_delta
            if e.id == prim {
                acc.id = e.id
            }
            continue
        }
        w += 1
        edits[w] = e
    }
    return edits[:w + 1]
}

// The caret id rides as the tag. Temp-allocated.
doc_splices :: proc(fused: []Edit) -> []docs.Splice {
    out := make([]docs.Splice, len(fused), context.temp_allocator)
    for e, i in fused {
        out[i] = {e.lo, e.hi, transmute([]u8)e.text, e.id}
    }
    return out
}

// After lues applied `fused` (doc_fuse's) to this doc at `gen`: the journal, where the carets
// go, and the undo step's carets when `record`. True when the bytes moved.
doc_landed :: proc(d: ^Doc, fused: []Edit, gen: u64, record: bool, cur := Commit{},
                   tab := 4) -> bool {
    moved := d.gen != gen
    if moved && d.sink.write != nil {
        #reverse for e in fused {
            if !edit_is_noop(e) {
                d.sink.write(d.sink.user, e.lo, e.hi - e.lo, e.text)
            }
        }
    }
    before := cursors_pack(d) if moved && record else nil
    if len(fused) > 0 || cur.policy == .Set {
        carets_land(d, fused, cur, tab)
    }
    doc_changes_ack(d, .Carets)
    if moved && record {
        undo_landed(d, fused, before)
    }
    return moved
}

@(private = "file")
carets_land :: proc(d: ^Doc, fused: []Edit, cur: Commit, tab: int) {
    switch cur.policy {
    case .Follow:
        prim := d.cursors[d.primary].id
        clear(&d.cursors)
        cum := 0
        for e in fused {
            p := doc_pos(d, e.lo + cum + len(e.text))
            cum += len(e.text) - (e.hi - e.lo)
            // same line, by contract
            p.col = clamp(p.col - e.caret_delta, 0, doc_line_len(d, p.line))
            q := doc_clamp_pos(d, p)
            // The caret an edit leaves IS the caret that asked for it (VIEWS.md §12); one nobody
            // asked for is named fresh.
            append(&d.cursors, new_cursor(d, q, q, -1, e.id))
        }
        d.primary = cursor_index(d, prim)
        doc_merge_cursors(d)
    case .Shift:
        changes, lost := doc_changes_since(d, .Carets)
        for &c in d.cursors {
            if !lost {
                for ch in changes {
                    c.anchor = docs.point_shift(c.anchor, ch, low = false)
                    c.head = docs.point_shift(c.head, ch, low = false)
                }
            }
            c.anchor, c.head = doc_clamp_pos(d, c.anchor), doc_clamp_pos(d, c.head)
        }
    case .Pin:
        // Clamped only: the document can be shorter than the rows the carets sit on.
        for &c in d.cursors {
            c.anchor, c.head = doc_clamp_pos(d, c.anchor), doc_clamp_pos(d, c.head)
        }
    case .Set:
        doc_set_cursors(d, cur.set, cur.primary, tab)
        doc_merge_cursors(d) // normalization, not policy: one rule for every placed caret
    }
}

// Oldest first. `lost` means the log no longer reaches back that far, so the reader rebuilds
// from the document.
doc_changes_since :: proc(d: ^Doc, who: Doc_Reader) -> (changes: []docs.Change, lost: bool) {
    return docs.changes_since(d.core, d.readers[who])
}

doc_changes_ack :: proc(d: ^Doc, who: Doc_Reader) {
    docs.changes_ack(d.core, d.readers[who])
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

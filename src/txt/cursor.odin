package txt

import "core:slice"
import "core:unicode/utf8"

// Where the carets are: the Cursor type and every verb that places, selects or moves them
// (VIEWS.md §4). Nothing here edits text — a verb decides positions, and doc.odin's edit
// funnel fans out over the set it leaves.
//
// The set is sorted by range start and non-overlapping only AFTER doc_merge_cursors, which
// motion and the selection verbs end with. A placement verb appends and leaves the order to the
// next merge, so nothing may assume one; edit_cursors is what stops a coincident pair editing
// the same range twice.

// anchor == head means no selection; head is the moving caret. goal is the sticky column for
// vertical motion, in CELLS — a byte column would drift through multi-byte lines.
Cursor :: struct {
    anchor: Pos,
    head:   Pos,
    goal:   int,
}

// Where an edit leaves the carets. A parameter of the COMMIT, not a property of the document:
// one buffer takes a keystroke and a formatter on consecutive frames and wants a different
// answer for each.
Cursor_Policy :: enum {
    Follow, // one cursor per edit, at its end          — typing
    Shift,  // the old set, carried through the splices — formatting, indent, foreign
    Pin,    // line and column unchanged                — regen: the ROW is the identity
    Set,    // the author says exactly                  — computed motion
}

// The cursor half of a commit. `set` is read by .Set and ignored by the rest.
Commit :: struct {
    policy: Cursor_Policy,
    set:    []Cursor,
}

doc_reset_cursor :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    clear(&d.cursors)
    append(&d.cursors, Cursor{anchor = q, head = q, goal = doc_cell_col(d, q)})
    d.primary = 0
}

// The whole set, verbatim: the one place a caller's own answer to "where do the carets go"
// lands, so .Set, an undo restore and a plugin's computed motion cannot drift apart. Clamped,
// because the positions may have been read BEFORE the edit and the document can be shorter now.
// An empty set is nobody asking, since a Doc holds at least one cursor.
doc_set_cursors :: proc(d: ^Doc, src: []Cursor, primary: int) {
    if len(src) == 0 {
        return
    }
    clear(&d.cursors)
    for c in src {
        k := c
        k.anchor, k.head = doc_clamp_pos(d, c.anchor), doc_clamp_pos(d, c.head)
        append(&d.cursors, k)
    }
    d.primary = clamp(primary, 0, len(d.cursors) - 1)
}

// Esc out of a trail: keep only the primary.
doc_collapse_to_primary :: proc(d: ^Doc) {
    p := d.cursors[d.primary]
    clear(&d.cursors)
    append(&d.cursors, p)
    d.primary = 0
}

// Alt+A: leave a fixed cursor where the free caret is, which keeps roaming. The coincident pair
// collapses to one at the next edit.
doc_drop_anchor :: proc(d: ^Doc) {
    c := d.cursors[d.primary]
    append(&d.cursors, Cursor{anchor = c.head, head = c.head, goal = c.goal})
}

// The cursors an edit fans out over. Alt+A leaves a fixed cursor exactly under the free caret,
// and that pair names one range, not two — an edit per copy would apply it twice. Only the
// selection matters here, so a stale goal column does not split a coincident pair.
edit_cursors :: proc(d: ^Doc) -> []Cursor {
    out := make([dynamic]Cursor, 0, len(d.cursors), context.temp_allocator)
    next: for c in d.cursors {
        for k in out {
            if k.anchor == c.anchor && k.head == c.head {
                continue next
            }
        }
        append(&out, c)
    }
    return out[:]
}

cursor_has_selection :: proc(c: Cursor) -> bool {
    return c.anchor != c.head
}

doc_any_selection :: proc(d: ^Doc) -> bool {
    for c in d.cursors {
        if cursor_has_selection(c) {
            return true
        }
    }
    return false
}

// The primary drives the gutter, but a centred viewport should hold the top of the SET. Cursors
// are not kept globally sorted, so scan.
doc_top_cursor_line :: proc(d: ^Doc) -> int {
    line := d.cursors[0].head.line
    for c in d.cursors[1:] {
        line = min(line, c.head.line)
    }
    return line
}

cursor_range :: proc(c: Cursor) -> (lo, hi: Pos) {
    if pos_less(c.head, c.anchor) {
        return c.head, c.anchor
    }
    return c.anchor, c.head
}

// The last line a selection reaches: one ending at column 0 covers no text on that line — the
// caret sits there, the selection does not.
@(private = "file")
sel_last_line :: proc(lo, hi: Pos) -> int {
    return hi.line > lo.line && hi.col == 0 ? hi.line - 1 : hi.line
}

pos_less :: proc(a, b: Pos) -> bool {
    return a.line < b.line || (a.line == b.line && a.col < b.col)
}

// --- pointer-placed cursors --- Keyboard ops are motions; a pointer names an absolute
// position. All clamp — a stale layout must never index out of bounds.

// select=true keeps the anchor (shift-click); false collapses onto the new position. The same
// `cursor_place` a keyboard motion uses, with a destination instead of a direction.
doc_set_head :: proc(d: ^Doc, p: Pos, select: bool) {
    q := doc_clamp_pos(d, p)
    c := &d.cursors[d.primary]
    cursor_place(c, q, select)
    c.goal = doc_cell_col(d, q)
}

// Alt+click. Unlike doc_drop_anchor the NEW cursor is the one that goes on to move. No merge: a
// coincident drop stays a pair, collapsing at the next edit.
doc_add_cursor :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    append(&d.cursors, Cursor{anchor = q, head = q, goal = doc_cell_col(d, q)})
    d.primary = len(d.cursors) - 1
}

// --- placement (VIEWS.md §4) ---
//
// A caret is PLACED, not walked to. Motion is what the set does together; every verb below says
// where the NEXT caret goes and none of them roams, which is why there is no prefix key and no
// armed mode to make one.

// ctrl+alt+down / ctrl+alt+up: a caret one line past the edge of the set, in the column that
// edge is walking. Nothing to add off either end of the document.
doc_add_cursor_line :: proc(d: ^Doc, by: int, hidden: []Range = nil) -> bool {
    edge, goal := d.cursors[0].head, d.cursors[0].goal
    for c in d.cursors[1:] {
        if by > 0 ? c.head.line > edge.line : c.head.line < edge.line {
            edge, goal = c.head, c.goal
        }
    }
    // A PLACED caret obeys the same rule a moved one does (§7): a line no cell stands for is not
    // one to put a caret on, so this steps over a hidden run the way `.Down` does.
    line := visible_line(d, hidden, edge.line, by, 1)
    if line == edge.line || line < 0 || line >= doc_line_count(d) {
        return false
    }
    p := Pos{line, doc_byte_col(d, line, goal)}
    append(&d.cursors, Cursor{anchor = p, head = p, goal = goal})
    d.primary = len(d.cursors) - 1
    return true
}

// alt+d. Two halves under one key: with nothing selected the word under the primary becomes the
// selection, and every press after that puts a caret over the next occurrence of it, wrapping
// once. A press that finds an occurrence already taken has run out and does nothing.
doc_add_next_match :: proc(d: ^Doc) -> bool {
    if seed_selection(d) {
        return true
    }
    pat, ok := match_text(d)
    if !ok {
        return false
    }
    at, found := doc_find(d, pat, last_cursor_start(d), .Forward)
    if !found {
        return false
    }
    head := Pos{at.line, at.col + len(pat)}
    for c in d.cursors {
        // Through cursor_range: the seed keeps the drag's order, so a right-to-left one is
        // still the same occurrence.
        lo, hi := cursor_range(c)
        if lo == at && hi == head {
            return false
        }
    }
    append(&d.cursors, Cursor{anchor = at, head = head, goal = doc_cell_col(d, head)})
    d.primary = len(d.cursors) - 1
    return true
}

// alt+shift+d: the same seed, then a caret over every occurrence at once.
doc_add_all_matches :: proc(d: ^Doc) -> bool {
    if seed_selection(d) {
        return true
    }
    pat, ok := match_text(d)
    if !ok {
        return false
    }
    hits := doc_find_all(d, pat)
    if len(hits) == 0 {
        return false
    }
    doc_set_spans(d, hits)
    return true
}

// What a split leaves on each line. The editors do not agree — Sublime, Kakoune and Helix keep a
// selection per line, VS Code and JetBrains put a caret at each line's end — so this is a config
// line (`[cursor] split`) rather than an answer decided here.
Split :: enum {
    Selections,
    Carets,
}

// One cursor per line of each selection, over what that selection covers on the line. A cursor
// with no selection is left alone: splitting nothing would be a no-op that moved it.
doc_split_lines :: proc(d: ^Doc, into := Split.Selections) -> bool {
    out := make([dynamic]Cursor, 0, len(d.cursors), context.temp_allocator)
    split := false
    for c in d.cursors {
        if !cursor_has_selection(c) {
            append(&out, c)
            continue
        }
        split = true
        lo, hi := cursor_range(c)
        for line in lo.line ..= sel_last_line(lo, hi) {
            head := Pos{line, line == hi.line ? hi.col : doc_line_len(d, line)}
            anchor := into == .Carets ? head : Pos{line, line == lo.line ? lo.col : 0}
            append(&out, Cursor{anchor = anchor, head = head, goal = doc_cell_col(d, head)})
        }
    }
    if !split {
        return false
    }
    doc_set_cursors(d, out[:], 0)
    doc_merge_cursors(d)
    return true
}

// The first half of the two match verbs: the word under the primary, selected in place. True
// when this press was that half, so the set grows on the NEXT one and never on the same key
// that decided what to look for.
@(private = "file")
seed_selection :: proc(d: ^Doc) -> bool {
    c := &d.cursors[d.primary]
    if cursor_has_selection(c^) {
        return false
    }
    lo, hi := word_span(doc_line(d, c.head.line), c.head.col)
    if lo == hi {
        return false
    }
    c.anchor, c.head = Pos{c.head.line, lo}, Pos{c.head.line, hi}
    c.goal = doc_cell_col(d, c.head)
    return true
}

// What the match verbs look for: the primary's selection, on one line. doc_find is line by line
// because a literal pattern cannot cross a break, so a selection that does has no occurrences.
@(private = "file")
match_text :: proc(d: ^Doc) -> (string, bool) {
    c := d.cursors[d.primary]
    lo, hi := cursor_range(c)
    if !cursor_has_selection(c) || lo.line != hi.line {
        return "", false
    }
    return doc_text(d, lo, hi, context.temp_allocator), true
}

// Where the next match is searched from: the last caret in the document, so the set grows
// forward and wraps once rather than re-finding what is already taken.
@(private = "file")
last_cursor_start :: proc(d: ^Doc) -> Pos {
    out, _ := cursor_range(d.cursors[0])
    for c in d.cursors[1:] {
        lo, _ := cursor_range(c)
        if pos_less(out, lo) {
            out = lo
        }
    }
    return out
}

// What a drag needs, since a word-grade drag re-derives both ends every frame. The order is the
// gesture's and not normalised: the head stays where the eye is, and cursor_range orders on read.
doc_select_span :: proc(d: ^Doc, anchor, head: Pos) {
    a := doc_clamp_pos(d, anchor)
    h := doc_clamp_pos(d, head)
    clear(&d.cursors)
    append(&d.cursors, Cursor{anchor = a, head = h, goal = doc_cell_col(d, h)})
    d.primary = 0
}

// Every cursor at once, which is what a plugin that computed its own motion sends back (§9).
// The order inside a span is the caller's and is not normalised; overlapping spans fuse, the
// same way two edits at one word do.
doc_set_spans :: proc(d: ^Doc, spans: [][2]Pos) {
    if len(spans) == 0 {
        return
    }
    clear(&d.cursors)
    for s in spans {
        a, h := doc_clamp_pos(d, s[0]), doc_clamp_pos(d, s[1])
        append(&d.cursors, Cursor{anchor = a, head = h, goal = doc_cell_col(d, h)})
    }
    d.primary = 0
    doc_merge_cursors(d)
}

// The double-click. The head is the run's END, so a following Shift+Right extends forward.
doc_select_word :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    lo, hi := word_span(doc_line(d, q.line), q.col)
    doc_select_span(d, Pos{q.line, lo}, Pos{q.line, hi})
}

// The triple-click. The span is the line's TEXT, not the line plus its break — exactly what
// Home then Shift+End selects.
doc_select_line :: proc(d: ^Doc, line: int) {
    anchor, head := line_span(d, line)
    doc_select_span(d, anchor, head)
}

// Ctrl+L, which is the triple-click at every cursor: the trail is kept, since collapsing it
// would undo an Alt+A this verb has nothing to do with. Two cursors on one line fuse.
doc_select_lines :: proc(d: ^Doc) {
    for &c in d.cursors {
        c.anchor, c.head = line_span(d, c.head.line)
        c.goal = doc_cell_col(d, c.head)
    }
    doc_merge_cursors(d)
}

// Ctrl+A. One selection over everything, the head at the end so a following Shift+motion grows
// from where the eye is.
doc_select_all :: proc(d: ^Doc) {
    last := doc_line_count(d) - 1
    doc_select_span(d, Pos{0, 0}, Pos{last, doc_line_len(d, last)})
}

line_span :: proc(d: ^Doc, line: int) -> (anchor, head: Pos) {
    l := clamp(line, 0, doc_line_count(d) - 1)
    return Pos{l, 0}, Pos{l, doc_line_len(d, l)}
}

// The lines a LINE-WISE edit acts on: every line any cursor touches, ascending and without
// repeats. doc_select_lines asks the smaller question (the line each caret sits on); this one
// reads the selection, and sel_last_line is what stops a full-line sweep from taking the line
// below it as well.
doc_cursor_lines :: proc(d: ^Doc, alloc := context.temp_allocator) -> []int {
    out := make([dynamic]int, 0, 8, alloc)
    for c in d.cursors {
        lo, hi := cursor_range(c)
        last := sel_last_line(lo, hi)
        for line in lo.line ..= last {
            append(&out, line)
        }
    }
    slice.sort(out[:])
    w := 0
    for line in out {
        if w == 0 || out[w - 1] != line {
            out[w] = line
            w += 1
        }
    }
    return out[:w]
}

// Word (2) or line (3+); grade 1 is doc_set_head. `press` and `at` carry glyph positions, not
// caret boundaries. Expanded per frame, so a double-click-drag grows by whole words.
doc_drag_span :: proc(d: ^Doc, grade: int, press, at: Pos) -> (anchor, head: Pos) {
    p := doc_clamp_pos(d, press)
    q := doc_clamp_pos(d, at)
    if grade >= 3 {
        // Compare LINES, not positions: dragging left within the pressed line has not
        // reversed the gesture.
        if q.line >= p.line {
            return Pos{p.line, 0}, Pos{q.line, doc_line_len(d, q.line)}
        }
        return Pos{p.line, doc_line_len(d, p.line)}, Pos{q.line, 0}
    }
    plo, phi := word_span(doc_line(d, p.line), p.col)
    qlo, qhi := word_span(doc_line(d, q.line), q.col)
    if !pos_less(q, p) {
        return Pos{p.line, plo}, Pos{q.line, qhi}
    }
    return Pos{p.line, phi}, Pos{q.line, qlo}
}

// The command line's "park at end" after a text swap.
doc_cursor_to_end :: proc(d: ^Doc) {
    last := doc_line_count(d) - 1
    doc_reset_cursor(d, Pos{last, doc_line_len(d, last)})
}

// --- movement --- select=true extends; a plain move with a selection collapses to the edge it
// moves toward, GUI-style. Vertical motion keeps the goal column.

Motion :: enum {
    Left,
    Right,
    Word_Left,
    Word_Right,
    Home,
    End,
    Doc_Start,
    Doc_End,
    Up,
    Down,
}

// A run of the ORIGINAL that a view stage deleted, so no cell on screen stands for it
// (VIEWS.md §7). Motion is the only thing in txt that is told about one — edits, undo, find and
// the journal all stay in original coordinates and never ask.
//
// lo and hi draw at the SAME cell, so the two edges are one position to the eye and the
// direction of travel is what picks between them: a rune typed at lo joins the text before the
// run, one typed at hi joins the text after it.
Range :: struct {
    lo, hi: Pos,
}

// Every caret at once, because a motion is what the SET does (VIEWS.md §4). Single cursor is
// N == 1, so an ordinary arrow is unchanged, and two carets moving into each other fuse.
// `count` applies to Up/Down only.
//
// `hidden` is what the view pipeline exports to motion and the whole of it: the runs of this
// document that are not on screen. Empty is a document nobody folded.
doc_move :: proc(d: ^Doc, motion: Motion, select := false, count := 1, hidden: []Range = nil) {
    for &c in d.cursors {
        move_cursor(d, &c, motion, select, count, hidden)
    }
    doc_merge_cursors(d)
}

@(private = "file")
move_cursor :: proc(d: ^Doc, c: ^Cursor, motion: Motion, select: bool, count := 1,
                    hidden: []Range = nil) {
    defer clamp_visible(d, c, motion, select, hidden)
    switch motion {
    case .Left:
        if !select && cursor_has_selection(c^) {
            lo, _ := cursor_range(c^)
            cursor_place(c, lo, false)
        } else {
            // Off the far edge FIRST: a step taken from the near edge would land back on the
            // same cell, so the fold would cost two presses to cross.
            cursor_place(c, pos_left(d, hidden_edge(hidden, c.head, true)), select)
        }
        c.goal = doc_cell_col(d, c.head)
    case .Right:
        if !select && cursor_has_selection(c^) {
            _, hi := cursor_range(c^)
            cursor_place(c, hi, false)
        } else {
            cursor_place(c, pos_right(d, hidden_edge(hidden, c.head, false)), select)
        }
        c.goal = doc_cell_col(d, c.head)
    case .Word_Left:
        cursor_place(c, Pos{c.head.line, word_left_index(doc_line(d, c.head.line), c.head.col)}, select)
        c.goal = doc_cell_col(d, c.head)
    case .Word_Right:
        cursor_place(c, Pos{c.head.line, word_right_index(doc_line(d, c.head.line), c.head.col)}, select)
        c.goal = doc_cell_col(d, c.head)
    case .Home:
        // The indentation first, column 0 on the second press: a line begins in two places and
        // this is the only key that reaches either.
        lead := line_indent_cols(doc_line(d, c.head.line))
        cursor_place(c, Pos{c.head.line, c.head.col == lead ? 0 : lead}, select)
        c.goal = doc_cell_col(d, c.head)
    case .End:
        cursor_place(c, Pos{c.head.line, doc_line_len(d, c.head.line)}, select)
        c.goal = doc_cell_col(d, c.head)
    case .Doc_Start:
        cursor_place(c, Pos{0, 0}, select)
        c.goal = doc_cell_col(d, c.head)
    case .Doc_End:
        last := doc_line_count(d) - 1
        cursor_place(c, Pos{last, doc_line_len(d, last)}, select)
        c.goal = doc_cell_col(d, c.head)
    case .Up:
        line := visible_line(d, hidden, c.head.line, -1, count)
        if line != c.head.line {
            cursor_place(c, Pos{line, doc_byte_col(d, line, c.goal)}, select)
        }
    case .Down:
        line := visible_line(d, hidden, c.head.line, +1, count)
        if line != c.head.line {
            cursor_place(c, Pos{line, doc_byte_col(d, line, c.goal)}, select)
        }
    }
}

// --- hidden runs (VIEWS.md §7) --- Every arm skips an obstacle rather than converting a
// coordinate: motion runs in ORIGINAL coordinates and this list is the only thing it knows
// about the view.

// Which edge an arm ends on. Doc_Start is rightward because the first visible position of a
// document that opens inside a fold is to the RIGHT of it.
@(private = "file")
RIGHTWARD :: bit_set[Motion]{.Right, .Word_Right, .End, .Doc_Start}

@(private = "file")
VERTICAL :: bit_set[Motion]{.Up, .Down}

// No arm may leave a caret inside hidden text, including the ones §7 calls unaffected: a
// line-local motion is only unaffected while the fold is not inline. Vertical motion keeps its
// goal column, since both edges are one cell and the caret has not moved horizontally.
@(private = "file")
clamp_visible :: proc(d: ^Doc, c: ^Cursor, motion: Motion, select: bool, hidden: []Range) {
    p := hidden_edge(hidden, c.head, motion not_in RIGHTWARD)
    if p == c.head {
        return
    }
    cursor_place(c, p, select)
    if motion not_in VERTICAL {
        c.goal = doc_cell_col(d, p)
    }
}

// The visible edge of the run p fell into, or p when it fell into none. Loops because two runs
// can meet, and the edge of one is then inside the next.
@(private = "file")
hidden_edge :: proc(hidden: []Range, p: Pos, toward_lo: bool) -> Pos {
    out := p
    for _ in 0 ..< len(hidden) {
        moved := false
        for r in hidden {
            if pos_less(out, r.lo) || pos_less(r.hi, out) {
                continue
            }
            if e := toward_lo ? r.lo : r.hi; e != out {
                out, moved = e, true
            }
        }
        if !moved {
            break
        }
    }
    return out
}

// A line with no row of its own: its start was swallowed, so its text draws as part of an
// earlier row and a caret can never be put on it.
@(private = "file")
line_hidden :: proc(hidden: []Range, line: int) -> bool {
    return hidden_edge(hidden, Pos{line, 0}, true).line != line
}

// `count` visible lines up or down, stopping on the last one there is — which is what an arrow
// at the edge of the document already did.
@(private = "file")
visible_line :: proc(d: ^Doc, hidden: []Range, from, by, count: int) -> int {
    out, line, n := from, from, doc_line_count(d)
    for _ in 0 ..< count {
        line += by
        // STRAIGHT TO THE RUN'S EDGE, never line by line: a fold is one step whatever its size,
        // and a 50,000-line one must not cost 50,000 iterations. The edge itself can still be
        // swallowed — a run that ends mid-line leaves that line with no row — so the step past
        // it is taken only then.
        for line >= 0 && line < n && line_hidden(hidden, line) {
            e := hidden_edge(hidden, Pos{line, 0}, by < 0)
            line = e.line
            if line_hidden(hidden, line) {
                line += by
            }
        }
        if line < 0 || line >= n {
            return out
        }
        out = line
    }
    return out
}

// --- internals ---

@(private = "file")
cursor_place :: proc(c: ^Cursor, to: Pos, select: bool) {
    c.head = to
    if !select {
        c.anchor = to
    }
}

// One rune left / right, wrapping across the line break.
@(private = "file")
pos_left :: proc(d: ^Doc, p: Pos) -> Pos {
    if p.col > 0 {
        _, size := doc_rune_before(d, p)
        return Pos{p.line, p.col - size}
    }
    if p.line > 0 {
        return Pos{p.line - 1, doc_line_len(d, p.line - 1)}
    }
    return p
}

@(private = "file")
pos_right :: proc(d: ^Doc, p: Pos) -> Pos {
    src := doc_line(d, p.line)
    if p.col < len(src) {
        _, size := utf8.decode_rune(src[p.col:])
        return Pos{p.line, p.col + max(size, 1)}
    }
    if p.line < doc_line_count(d) - 1 {
        return Pos{p.line + 1, 0}
    }
    return p
}

// Sort by selection start and fuse any that overlap or touch.
doc_merge_cursors :: proc(d: ^Doc) {
    if len(d.cursors) <= 1 {
        return
    }
    slice.sort_by(d.cursors[:], proc(a, b: Cursor) -> bool {
        alo, _ := cursor_range(a)
        blo, _ := cursor_range(b)
        return pos_less(alo, blo)
    })
    w := 0
    for r in 1 ..< len(d.cursors) {
        alo, ahi := cursor_range(d.cursors[w])
        blo, bhi := cursor_range(d.cursors[r])
        if pos_less(ahi, blo) { // disjoint
            w += 1
            d.cursors[w] = d.cursors[r]
        } else if pos_less(ahi, bhi) { // overlap: fuse into the union
            d.cursors[w] = Cursor{anchor = alo, head = bhi, goal = doc_cell_col(d, bhi)}
        }
    }
    resize(&d.cursors, w + 1)
    d.primary = clamp(d.primary, 0, w)
}

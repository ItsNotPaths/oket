package main

import "core:strings"
import "core:unicode/utf8"
import "../desc"
import "../input"
import vt "../libvterm"
import "../plug"
import "../pty"
import "../store"
import "../txt"

// The terminal kind (§7: the kernel may implement a document, it may not have a second way to
// be one). A session is a PTY, a libvterm state machine, and a DOCUMENT: scrollback lines
// followed by the live grid's rows, one document line per physical row.
//
// That is the whole of why there is no terminal scroll code. The kernel's viewport scrolls it
// like anything else, `follow: tail` is the live bottom, point is the caret, and a drag selects
// for copy. What is left that a text document does not have is colour, and that goes into the
// span store like everybody else's (store/spans.odin), under the name `term`: the kernel is a
// publisher here and config ranks it beside the plugins, because a terminal is one more thing
// with an opinion about what its bytes look like.
//
// The descriptor says the rest: `render: grid`, `input: raw` so an unclaimed chord reaches the
// shell, and `mouse: events` while a TUI has tracking on.

Term :: struct {
    t:      pty.Terminal,
    doc:    store.Id,
    // Document line 0's absolute line number, and how many document lines are scrollback.
    // Everything past `fixed` is the live grid and is rewritten on every pump.
    base:   int,
    fixed:  int,
    // Last pump's runs, in DOCUMENT bytes, kept so a rewrite can replace the tail without
    // re-measuring the scrollback above it. The store holds the same list; this is what the
    // next publish is built from.
    spans:  [dynamic]store.Span,
    // The mouse mode the descriptor was last published with, so a pump republishes only when
    // the TUI actually turns tracking on or off.
    events: bool,
}

// Where a session starts: N0's shell, wherever a `cd` in the command line has left it, and the
// directory the start was given when there is no N0 to ask. N0 itself takes the fallback, which
// is what stops this asking for a session while one is being made.
@(private = "file")
term_dir :: proc(a: ^App) -> string {
    if !a.ring.system.live {
        return a.dir
    }
    tm := term_of(a, a.ring.system.doc)
    if tm == nil {
        return a.dir
    }
    dir := pty.terminal_cwd(&tm.t)
    return dir != "" ? dir : a.dir
}

// Spawned at a nominal size in `term_dir`; the first pump resizes it to the body. Heap-allocated
// because the reader thread holds a pointer into it.
term_open :: proc(a: ^App) -> (store.Id, bool) {
    tm := new(Term)
    if !pty.terminal_spawn(&tm.t, 24, 80, term_dir(a)) {
        free(tm)
        message_set(a, "could not spawn a shell")
        return {}, false
    }
    pty.terminal_set_default_colors(&tm.t, a.theme[.Fg], a.theme[.Bg])
    tm.doc = store.store_open(&a.docs, "")
    term_publish(a, tm)
    store.store_drain(&a.docs)
    if a.terms == nil {
        a.terms = make(map[store.Id]^Term)
    }
    a.terms[tm.doc] = tm
    return tm.doc, true
}

term_close :: proc(a: ^App, id: store.Id) {
    tm, found := a.terms[id]
    if !found {
        return
    }
    delete_key(&a.terms, id)
    pty.terminal_close(&tm.t)
    delete(tm.spans)
    free(tm)
}

terms_destroy :: proc(a: ^App) {
    for _, tm in a.terms {
        pty.terminal_close(&tm.t)
        delete(tm.spans)
        free(tm)
    }
    delete(a.terms)
    a.terms = nil
}

term_of :: proc(a: ^App, id: store.Id) -> ^Term {
    return a.terms[id]
}

// The focused document's session, for the verbs that need one. nil everywhere else, which is
// what keeps `term.paste` from pasting into a listing.
term_active :: proc(a: ^App) -> ^Term {
    s := active(a)
    return s == nil ? nil : a.terms[s.doc]
}

// --- the frame ---

// After the reader has bytes and before the draw: every session's output into its document.
// The chain never learns that its shell step is running in one of these.
term_pump :: proc(a: ^App) {
    for _, tm in a.terms {
        term_session_pump(a, tm)
    }
}

@(private = "file")
term_session_pump :: proc(a: ^App, tm: ^Term) {
    s := term_slot(a, tm.doc)
    r := doc_rect(a, tm.doc)
    // The body is last frame's, and it is zero until the first draw. Resizing to that would
    // hand the shell a one-cell window and mangle the prompt it is in the middle of writing.
    if s != nil && r.w > 0 && r.h > 0 {
        pty.terminal_resize(&tm.t, r.h, r.w)
    }
    pty.terminal_drain(&tm.t)

    doc := store.store_doc(&a.docs, tm.doc)
    if doc == nil {
        return
    }
    was := txt.doc_line_count(doc)
    term_trim(a, tm, doc)
    term_rewrite(a, tm, doc)
    term_follow(s, doc, was, max(r.h, 1))
    term_point(tm, s, doc)
    if tm.events != tm.t.mouse_on {
        term_publish(a, tm)
    }
}

// Scrollback ran past its cap and the oldest lines went. The document drops the same lines, so
// document line 0 and `base` stay the same row.
@(private = "file")
term_trim :: proc(a: ^App, tm: ^Term, doc: ^txt.Doc) {
    drop := pty.terminal_oldest(&tm.t) - tm.base
    if drop <= 0 {
        return
    }
    cut := txt.doc_off(doc, {min(drop, txt.doc_line_count(doc)), 0})
    txt.doc_apply(doc, {{0, cut, "", 0, 0}})
    tm.base += drop
    tm.fixed = max(tm.fixed - drop, 0)
    kept := 0
    for sp in tm.spans {
        if sp.lo >= cut {
            tm.spans[kept] = sp
            tm.spans[kept].lo -= cut
            tm.spans[kept].hi -= cut
            kept += 1
        }
    }
    resize(&tm.spans, kept)
    // The whole list, because every run that survived moved. This is the one path that
    // republishes frozen scrollback, and it runs only when the cap is crossed.
    store.store_spans_publish(&a.docs, tm.doc,
                              {producer_intern(a, TERM_PRODUCER), 0, max(int), tm.spans[:]})
}

// Everything from the first line that is not yet frozen: the scrollback lines pushed since the
// last pump, then the live grid. Bounded by the grid's height plus what scrolled off in one
// frame, so a session that has been open all day still costs one screen a pump.
@(private = "file")
term_rewrite :: proc(a: ^App, tm: ^Term, doc: ^txt.Doc) {
    from := tm.fixed
    // Where the rewrite starts, taken FIRST: a run is document bytes, so the offset the rows
    // below are measured from has to be the one they will land at.
    lo := txt.doc_off(doc, {min(from, txt.doc_line_count(doc)), 0})
    frozen := 0
    for sp in tm.spans {
        if sp.lo >= lo {
            break
        }
        frozen += 1 // below the rewrite, so it was published in an earlier pass
    }
    resize(&tm.spans, frozen)
    b := strings.builder_make(context.temp_allocator)
    // The cursor's own cell is something you can see, so the blank trim below stops short of
    // it: a prompt's caret sits one past the last glyph, and trimming there would draw it on
    // top of the prompt instead.
    crow, ccol := pty.terminal_cursor(&tm.t)
    cursor := tm.t.sb_total + crow
    for n in tm.base + from ..= pty.terminal_bottom(&tm.t) {
        if n > tm.base + from {
            strings.write_byte(&b, '\n')
        }
        term_line(a, tm, n, &b, lo, n == cursor ? ccol + 1 : 0)
    }
    txt.doc_apply(doc, {{lo, txt.doc_len(doc), strings.to_string(b), 0, 0}})
    tm.fixed = len(tm.t.scrollback)
    // To the END and not to the new length: a screen that shrank must not leave the runs that
    // were under what it dropped.
    store.store_spans_publish(&a.docs, tm.doc,
                              {producer_intern(a, TERM_PRODUCER), lo, max(int),
                               tm.spans[frozen:]})
}

// One physical row as text plus its style runs. Trailing blanks go only where they carry the
// default background: what you cannot see is not worth copying, and a TUI's full-width bar is
// exactly what you would lose by trimming on the rune alone.
// `base` is where the builder's first byte lands in the document, so a run's offsets are the
// document's own: a colour is stored against bytes, never against a line and a column.
@(private = "file")
term_line :: proc(a: ^App, tm: ^Term, n: int, b: ^strings.Builder, base, keep: int) {
    end := max(term_line_end(a, tm, n), min(keep, pty.terminal_line_width(&tm.t, n)))
    run := store.Span{lo = base + strings.builder_len(b^)}
    open := false
    for col := 0; col < end; {
        cell, ok := pty.terminal_line_cell(&tm.t, n, col)
        if !ok {
            break
        }
        at := base + strings.builder_len(b^)
        st := term_style(a, tm, cell, at)
        if !open || st.fg != run.fg || st.bg != run.bg || st.attrs != run.attrs {
            term_close_run(a, tm, &run, at)
            run, open = st, true
        }
        r := rune(cell.chars[0])
        strings.write_rune(b, r >= 0x20 ? r : ' ')
        col += max(int(cell.width), 1)
    }
    term_close_run(a, tm, &run, base + strings.builder_len(b^))
}

// A run reaches the styles only if it has cells in it and says something the theme does not
// already say — a screen of plain output publishes nothing at all.
@(private = "file")
term_close_run :: proc(a: ^App, tm: ^Term, run: ^store.Span, at: int) {
    run.hi = at
    plain := run.fg == a.theme[.Fg] && run.bg == a.theme[.Bg] && run.attrs == 0
    if run.hi > run.lo && !plain {
        append(&tm.spans, run^)
    }
    run.lo = at
}

// libvterm's colours resolved against the theme, so the renderer never sees an SGR. Reverse is
// the swap and not an attribute: the caret and the selection are the renderer's own reverse, and
// two of them over one cell cancel out.
@(private = "file")
term_style :: proc(a: ^App, tm: ^Term, cell: vt.ScreenCell, at: int) -> store.Span {
    // All three channels, always: a cell is a resolved colour on a resolved background, and a
    // terminal that left one to whoever is below it would draw somebody else's paint inside a
    // TUI's own.
    st := store.Span{lo = at, set = {.Fg, .Bg, .Attrs}}
    fg, fdef := pty.terminal_color(&tm.t, cell.fg)
    bg, bdef := pty.terminal_color(&tm.t, cell.bg)
    st.fg = fdef ? a.theme[.Fg] : fg
    st.bg = bdef ? a.theme[.Bg] : bg
    if cell.attrs.reverse {
        st.fg, st.bg = st.bg, st.fg
    }
    if cell.attrs.bold {
        st.attrs |= u8(plug.Attr.Bold)
    }
    if cell.attrs.italic {
        st.attrs |= u8(plug.Attr.Italic)
    }
    if cell.attrs.underline != 0 {
        st.attrs |= u8(plug.Attr.Underline)
    }
    return st
}

// The last column worth keeping: past it the row is blank cells on the default background,
// which draw as nothing and paste as trailing spaces. `keep` at the call site is what stops
// this taking the cursor's cell with them.
@(private = "file")
term_line_end :: proc(a: ^App, tm: ^Term, n: int) -> int {
    w := pty.terminal_line_width(&tm.t, n)
    for w > 0 {
        cell, ok := pty.terminal_line_cell(&tm.t, n, w - 1)
        if !ok {
            w -= 1
            continue
        }
        _, bdef := pty.terminal_color(&tm.t, cell.bg)
        if rune(cell.chars[0]) > 0x20 || !bdef || cell.attrs.reverse {
            break
        }
        w -= 1
    }
    return w
}

// `follow: tail` (§5, §11): the view rides the end while it is already showing it. Scrolling up
// parks you and scrolling back picks it up again, so there is no attached flag to fall out of
// step with what is on screen.
@(private = "file")
term_follow :: proc(s: ^Slot, doc: ^txt.Doc, was, h: int) {
    if s == nil || s.view.top + h < was {
        return // no slot to move, or parked above the bottom: the new lines wait for you there
    }
    s.view.top = max(txt.doc_line_count(doc) - h, 0)
}

// Point IS the shell's cursor while nothing is selected, so the caret the renderer draws for
// every document is the one a terminal wants and there is no second cursor to keep in step. A
// selection is the user's, and output does not take it away.
@(private = "file")
term_point :: proc(tm: ^Term, s: ^Slot, doc: ^txt.Doc) {
    if txt.cursor_has_selection(doc.cursors[doc.primary]) {
        return
    }
    row, col := pty.terminal_cursor(&tm.t)
    line := tm.t.sb_total - tm.base + row
    txt.doc_reset_cursor(doc, {line, term_col_byte(tm, line, col)})
    if s != nil {
        s.view.point = doc.cursors[doc.primary]
    }
}

// The cursor's COLUMN is a cell, and the document's is a byte. One walk of the row converts.
@(private = "file")
term_col_byte :: proc(tm: ^Term, line, want: int) -> (off: int) {
    n := tm.base + line
    for col := 0; col < want; {
        cell, ok := pty.terminal_line_cell(&tm.t, n, col)
        if !ok {
            break
        }
        r := rune(cell.chars[0])
        off += utf8.rune_size(r >= 0x20 ? r : ' ')
        col += max(int(cell.width), 1)
    }
    return
}

// The descriptor (§5). Published at open and again when the TUI takes the mouse over; nothing
// else about a session's behaviour moves.
@(private = "file")
term_publish :: proc(a: ^App, tm: ^Term) {
    gen, _ := store.store_gen(&a.docs, tm.doc)
    tm.events = tm.t.mouse_on
    d := desc.new_from(
        {
            render = .Grid,
            ctx = kind_ctx(a, KIND_TERM),
            kind = KIND_TERM,
            selection = .Char,
            follow = .Tail,
            input = .Raw,
            mouse = tm.events ? .Events : .Bound,
            tab_width = 8,
        },
    )
    store.store_submit(&a.docs, tm.doc, gen, nil, d)
    desc.release(d)
}

// The slot a session is drawn in, and the reason the pump can move a viewport at all. Sessions
// are few, so this is a walk and not a second index to keep in step with the ring.
@(private = "file")
term_slot :: proc(a: ^App, id: store.Id) -> ^Slot {
    if a.ring.system.live && a.ring.system.doc == id {
        return &a.ring.system
    }
    for &l in a.ring.lanes {
        for &s in l.slots {
            if s.live && s.doc == id {
                return &s
            }
        }
    }
    return nil
}

// --- input ---

// A rune the bind table never saw (§8). `input: raw` is what routes it here.
term_text :: proc(tm: ^Term, r: rune) {
    pty.terminal_input_rune(&tm.t, r)
}

// The miss rule's target: a chord no row claimed, as the shell sees it. Specials go by physical
// name; Ctrl+letter follows the LAYOUT's letter, so Ctrl+C is the C under your fingers.
// Anything else is dropped — a printable arrives as text, on its own channel.
term_send :: proc(a: ^App, tm: ^Term, chord: input.Chord) {
    key: vt.Key
    switch input.key_name(chord.code) {
    case "RTRN", "KPEN":
        key = .Enter
    case "TAB":
        key = .Tab
    case "BKSP":
        key = .Backspace
    case "ESC":
        key = .Escape
    case "UP":
        key = .Up
    case "DOWN":
        key = .Down
    case "LEFT":
        key = .Left
    case "RGHT":
        key = .Right
    case "HOME":
        key = .Home
    case "END":
        key = .End
    case "INS":
        key = .Ins
    case "DELE":
        key = .Del
    case "PGUP":
        key = .PageUp
    case "PGDN":
        key = .PageDown
    case:
        // Shift does not change a control character: ctrl+shift+c is the 0x03 ctrl+c is, which
        // is what every other terminal encodes and what lets `ctrl+shift+c = surface.send` be
        // the interrupt row. Written out rather than `.Ctrl in mods`, so ctrl+alt stays unsent
        // until something asks it to mean the ESC prefix.
        if chord.mods == {.Ctrl} || chord.mods == {.Ctrl, .Shift} {
            if l := key_layout_name(chord.code); len(l) == 1 && l[0] >= 'a' && l[0] <= 'z' {
                pty.terminal_input_ctrl(&tm.t, rune(l[0]))
            }
        }
        return
    }
    pty.terminal_input_key(&tm.t, key, term_mods(chord.mods))
}

// Shift and Ctrl only. Alt stays global, so the shell never sees an Alt chord and alt+N is
// always the ring.
term_mods :: proc(m: input.Mods) -> (r: vt.Modifier) {
    if .Shift in m {
        r |= vt.MOD_SHIFT
    }
    if .Ctrl in m {
        r |= vt.MOD_CTRL
    }
    return
}

// A pointer position over a document whose descriptor says `mouse: events` (§5, §8). The cell
// is already the kernel's — pixel to cell is a division and the row is the viewport's — so what
// is left is turning a document line back into the grid row the TUI knows it as. False off the
// live grid, which is where the scrollback is and where a TUI has nothing to be told about.
term_mouse_at :: proc(a: ^App, tm: ^Term, cx, cy: int, mods: input.Mods) -> bool {
    s := term_slot(a, tm.doc)
    if s == nil {
        return false
    }
    r := doc_rect(a, tm.doc) // the cell arrived in the panel's own lattice, so this is too
    row := s.view.top + cy - r.y - (tm.t.sb_total - tm.base)
    col := cx - r.x
    if row < 0 || row >= tm.t.rows || col < 0 || col >= tm.t.cols {
        return false
    }
    pty.terminal_mouse_move(&tm.t, row, col, term_mods(mods))
    return true
}

// The same, and then the button. libvterm encodes both to whatever tracking mode the TUI
// turned on (terminal_mouse_move).
term_mouse :: proc(a: ^App, tm: ^Term, m: input.Mouse, cx, cy: int, mods: input.Mods, pressed: bool) {
    if !term_mouse_at(a, tm, cx, cy, mods) {
        return
    }
    if button := term_button(m); button != 0 {
        pty.terminal_mouse_button(&tm.t, button, pressed, term_mods(mods))
    }
}

// The wheel is buttons 4 and 5, which is the protocol's own spelling and not a convention of
// ours.
@(private = "file")
term_button :: proc(m: input.Mouse) -> int {
    #partial switch m {
    case .Click:
        return 1
    case .Middle_Click:
        return 2
    case .Right_Click:
        return 3
    case .Wheel_Up:
        return 4
    case .Wheel_Down:
        return 5
    }
    return 0
}

// --- the clipboard ---

// The document's selection, or the line point is on, to the system clipboard. A soft-wrapped
// command joins with nothing, so a copied line pastes back as one line.
term_copy :: proc(a: ^App) -> bool {
    tm := term_active(a)
    if tm == nil {
        return false
    }
    doc := store.store_doc(&a.docs, active(a).doc)
    if doc == nil {
        return false
    }
    c := doc.cursors[doc.primary]
    if !txt.cursor_has_selection(c) {
        txt.doc_select_line(doc, c.head.line)
        c = doc.cursors[doc.primary]
    }
    lo, hi := txt.cursor_range(c)
    text := term_unwrap(tm, txt.doc_text(doc, lo, hi, context.temp_allocator), lo.line)
    if text != "" {
        clip_set(a, text)
        message_set(a, "copied")
    }
    return true
}

// The newlines a soft wrap put in, taken back out. libvterm knows which rows exist only because
// the one above them ran off the edge, and a command copied over that edge is one command.
@(private = "file")
term_unwrap :: proc(tm: ^Term, text: string, from: int) -> string {
    b := strings.builder_make(context.temp_allocator)
    line := from
    for r in text {
        if r == '\n' {
            line += 1
            if pty.terminal_continuation(&tm.t, tm.base + line) {
                continue
            }
        }
        strings.write_rune(&b, r)
    }
    return strings.to_string(b)
}

// The clipboard into the shell, bracketed, so a multi-line paste lands in the line editor
// instead of running line by line.
term_paste :: proc(a: ^App) -> bool {
    tm := term_active(a)
    if tm == nil {
        return false
    }
    pty.terminal_paste(&tm.t, clip_get(a))
    return true
}

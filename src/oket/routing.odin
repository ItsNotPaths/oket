package main

import "core:fmt"
import "core:strings"
import "vendor:glfw"
import "../desc"
import "../input"
import "../store"
import "../txt"
import "../view"

// Cells in, document out. The window layer above divides pixels; nothing from here down knows
// what a pixel is, which is also how a test drives a click without a window.

// The document the keys act on: the command line while it is open, the focused slot otherwise
// (§11). One accessor is the whole reason the line needs no key code of its own — every motion,
// every selection verb and the renderer all reach it through here.
active :: proc(a: ^App) -> ^Slot {
    return cl_active(a) ? &a.cl.slot : ring_focused(&a.ring)
}

// Where that document was drawn, for a click. The line's row while it is open, the body
// otherwise, so a click never lands in a document the keys are not aimed at.
active_rect :: proc(a: ^App) -> Rect {
    return cl_active(a) ? a.bar : a.body
}

// The active slot and its descriptor, which is what every routing question below reads its
// answer off. The caller releases the descriptor; both nil for an empty ring or a closed doc.
@(private = "file")
active_desc :: proc(a: ^App) -> (^Slot, ^desc.Descriptor) {
    s := active(a)
    if s == nil {
        return nil, nil
    }
    return s, store.store_descriptor(&a.docs, s.doc)
}

// The focused document names its own context, and the descriptor is where it says so (§5). An
// empty store leaves only Global.
bind_ctx :: proc(a: ^App) -> (input.Bind_Ctx, input.Kind) {
    _, d := active_desc(a)
    if d == nil {
        return .Global, 0
    }
    defer desc.release(d)
    return d.ctx, d.kind
}

// A capture owns the keystroke: Escape clears it at any depth, anything else is the input it was
// waiting for.
@(private = "file")
pending_take :: proc(a: ^App, chord: input.Chord) -> bool {
    esc, _ := input.key_code("ESC")
    #partial switch _ in a.pending {
    case input.Pending_Describe:
        if chord == {esc, {}} {
            input.pending_cancel(&a.pending)
            return true
        }
        ctx, kind := bind_ctx(a)
        answer := input.describe_chord(a.binds[:], chord, ctx, key_layout_name, {}, kind,
                                       kind_name, context.temp_allocator)
        message_set(a, answer)
        a.pending = nil
        return true
    }
    return false
}

handle_chord :: proc(a: ^App, chord: input.Chord) {
    if pending_take(a, chord) {
        return
    }
    message_set(a, "")
    ctx, kind := bind_ctx(a)
    b, extend, ok := input.bind_lookup(a.binds[:], chord, ctx, kind)
    if !ok {
        // The miss rule (§8, §14): a context whose documents have a job of their own forwards,
        // and everything else stays quiet. A chord that IS bound and does nothing is the thing
        // that section exists to prevent; an unbound one is just an unbound one.
        if input.ctx_miss(ctx) == .Surface_Send {
            surface_send(a, chord)
        }
        return
    }
    if line, is_line := b.target.(input.Bind_Line); is_line {
        bind_line_fire(a, line)
        return
    }
    cmd, kernel := input.bind_command(b)
    if !kernel {
        message_set(a, "registered commands arrive with the plugin seam")
        return
    }
    // The line answers four chords for itself; everything else acts on it because `active`
    // says it is the document now.
    if cl_active(a) && cl_take(a, cmd) {
        return
    }
    if motion, moves := motion_of(cmd); moves {
        point_move(a, motion, extend)
        return
    }
    if edit_command(a, cmd) {
        return
    }
    #partial switch cmd {
    case .Quit:
        a.quit = true
    case .Describe_Key:
        a.pending = input.Pending_Describe{}
    case .View_Scroll_Up:
        scroll_by(a, -WHEEL_LINES)
    case .View_Scroll_Down:
        scroll_by(a, +WHEEL_LINES)
    case .View_Page_Up:
        scroll_by(a, -max(active_rect(a).h - 1, 1))
    case .View_Page_Down:
        scroll_by(a, +max(active_rect(a).h - 1, 1))
    case .Surface_Send:
        // A ROW named this, so a document with no job of its own has to say so: a bound chord
        // that quietly does nothing is the one thing §8 exists to prevent. The miss path above
        // stays silent, because an unbound chord was never a promise.
        if !surface_send(a, chord) {
            message_set(a, "this document has no job of its own")
        }
    case .Term_Copy:
        term_copy(a)
    case .Term_Paste:
        term_paste(a)
    case .Select_Expand:
        select_expand(a)
    case .Select_All:
        select_all(a)
    case .Ring_Goto:
        // One bind covers alt+1..9: the offset past the row's own code is the slot (§8).
        ring_open(a, int(chord.code - b.chord.code) + 1)
    case .Ring_Alt:
        ring_alt(&a.ring)
    case .Ring_Alt_Lane:
        ring_alt_lane(&a.ring)
    case .Ring_Close:
        ring_close(a, a.ring.focused)
    case .Ring_System:
        sys_slot(a) // alt+0 opens N# if nothing has needed it yet
        ring_show_system(a)
    case .CL_Open:
        cl_show(a)
    case .CL_Sigil:
        cl_show(a, ":")
    case:
        // A bound chord that does nothing at all is the one thing §8 exists to prevent, so a
        // verb whose stage has not landed says so rather than going quiet.
        message_set(a, fmt.tprintf("%s is not built yet", input.COMMANDS[cmd].name))
    }
}

// One wheel notch. A config value once config.conf lands (§4).
WHEEL_LINES :: 3

@(private = "file")
motion_of :: proc(cmd: input.Command) -> (txt.Motion, bool) {
    #partial switch cmd {
    case .Nav_Up:
        return .Up, true
    case .Nav_Down:
        return .Down, true
    case .Nav_Left:
        return .Left, true
    case .Nav_Right:
        return .Right, true
    case .Word_Left:
        return .Word_Left, true
    case .Word_Right:
        return .Word_Right, true
    case .Line_Home:
        return .Home, true
    case .Line_End:
        return .End, true
    case .Doc_Start:
        return .Doc_Start, true
    case .Doc_End:
        return .Doc_End, true
    }
    return {}, false
}

// Which verbs WRITE. Split from the bodies below so the refusal is decided in one place, and
// so a verb that only moves a selection is not caught by it.
@(private = "file")
writes :: proc(cmd: input.Command) -> bool {
    #partial switch cmd {
    case .Delete_Back, .Delete_Forward, .Delete_Word_Back, .Delete_Word_Forward, .Tab:
        return true
    }
    return false
}

// The text ops, over whatever `active` names: the command line serves its one row through the
// same code a document gets (§11). A document that does not take typing refuses, which is what
// stops a Backspace over a listing from eating the row it is standing on.
@(private = "file")
edit_command :: proc(a: ^App, cmd: input.Command) -> bool {
    if !writes(cmd) {
        return false
    }
    doc := writable(a)
    if doc == nil {
        message_set(a, "this document does not take typing")
        return true
    }
    #partial switch cmd {
    case .Delete_Back:
        txt.doc_backspace(doc)
    case .Delete_Forward:
        txt.doc_delete(doc)
    case .Delete_Word_Back:
        txt.doc_delete_word_back(doc)
    case .Delete_Word_Forward:
        txt.doc_delete_word_forward(doc)
    case .Tab:
        txt.doc_insert_text(doc, "\t")
    }
    point_sync(a)
    return true
}

// The active document, but only when its descriptor says typing reaches it.
@(private = "file")
writable :: proc(a: ^App) -> ^txt.Doc {
    s, d := active_desc(a)
    if d == nil {
        return nil
    }
    defer desc.release(d)
    return d.editable ? store.store_doc(&a.docs, s.doc) : nil
}

// A rune, not a chord (§8): binds see chords and never see an `a` on its way into a document.
// The command line takes typing, and `input: raw` sends it to the document's own job — which is
// the terminal, and is the whole of what that field is for. The editor plugin joins at stage 8.
text_input :: proc(a: ^App, r: rune) {
    if cl_active(a) {
        doc := store.store_doc(&a.docs, a.cl.doc)
        if doc == nil {
            return
        }
        txt.doc_insert_rune(doc, r)
        point_sync(a)
        return
    }
    if tm := raw_target(a); tm != nil {
        term_text(tm, r)
    }
}

// The focused document's own job, when its descriptor says input reaches it (§5). False is not
// a refusal to report: the caller decides, because a miss and a bound row answer it differently.
surface_send :: proc(a: ^App, chord: input.Chord) -> bool {
    tm := raw_target(a)
    if tm == nil {
        return false
    }
    term_send(a, tm, chord)
    return true
}

@(private = "file")
raw_target :: proc(a: ^App) -> ^Term {
    s, d := active_desc(a)
    if d == nil {
        return nil
    }
    defer desc.release(d)
    return d.input == .Raw ? term_of(a, s.doc) : nil
}

// Does a click over this document belong to the document rather than to the kernel (§5, §8).
// The one thing the mouse funnel has to ask before it moves point, and the answer is data on
// the descriptor rather than a kind the funnel would have to know the name of.
mouse_events_target :: proc(a: ^App) -> ^Term {
    s, d := active_desc(a)
    if d == nil {
        return nil
    }
    defer desc.release(d)
    return d.mouse == .Events ? term_of(a, s.doc) : nil
}

// The line arm of a bind (§8): holes filled from point, then run or staged as the file said.
// `exec` runs it, `stage` puts it in the command line for aiming — those two words are the
// whole grammar, and they are what makes Enter and Shift+Enter two rows over one value rather
// than two code paths in a plugin.
@(private = "file")
bind_line_fire :: proc(a: ^App, line: input.Bind_Line) {
    text, ok := bind_expand(a, line.text)
    if !ok {
        return
    }
    if line.stage {
        cl_show(a, text)
        return
    }
    cl_exec(a, text)
}

// The next `<name>` in a bind line: what comes before it, the name, and what is left. Shared by
// the hole filling and by hover, so the two cannot disagree about what a line asks for.
hole_next :: proc(s: string) -> (before, name, rest: string, ok: bool) {
    lo := strings.index_byte(s, '<')
    if lo < 0 {
        return s, "", "", false
    }
    hi := strings.index_byte(s[lo:], '>')
    if hi < 0 {
        return s, "", "", false
    }
    return s[:lo], s[lo + 1:lo + hi], s[lo + hi + 1:], true
}

// Fills every `<name>` from the fields of the line point is on (§5). A name the document does
// not carry stops the line and REPORTS rather than running one with a hole still in it (§14).
bind_expand :: proc(a: ^App, template: string) -> (string, bool) {
    s := active(a)
    if s == nil {
        return "", false
    }
    snap, d, ok := reading(a, s)
    if !ok {
        return "", false
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)

    b := strings.builder_make(context.temp_allocator)
    rest := template
    for {
        before, name, tail, found := hole_next(rest)
        strings.write_string(&b, before)
        if !found {
            break
        }
        value, got := view.field_text(&snap.text, d, s.view.point.head.line, name)
        if !got {
            message_set(a, fmt.tprintf("nothing here has a %s", name))
            return "", false
        }
        strings.write_string(&b, sh_arg(value))
        rest = tail
    }
    return strings.to_string(b), true
}

// --- point and the viewport ---

// The caret lives in the document and nowhere else; the slot's View carries a copy so the frame
// can render it. This is the one place that copy is made.
point_sync :: proc(a: ^App) {
    s := active(a)
    if s == nil {
        return
    }
    if doc := store.store_doc(&a.docs, s.doc); doc != nil {
        s.view.point = doc.cursors[doc.primary]
    }
}

// The read pair every event wants: the frozen text and the descriptor its generation named. The
// caller releases both.
@(private = "file")
reading :: proc(a: ^App, s: ^Slot) -> (^txt.Snapshot, ^desc.Descriptor, bool) {
    if s == nil {
        return nil, nil, false
    }
    snap := store.store_snapshot(&a.docs, s.doc)
    if snap == nil {
        return nil, nil, false
    }
    return snap, store.store_descriptor(&a.docs, s.doc), true
}

point_move :: proc(a: ^App, motion: txt.Motion, extend: bool) {
    s := active(a)
    doc := s != nil ? store.store_doc(&a.docs, s.doc) : nil
    if doc == nil {
        return
    }
    txt.doc_move(doc, motion, extend)
    point_sync(a)
    r := active_rect(a)
    view.follow(&s.view, r.h)
}

// Where a click lands. Outside the document's rectangle the caret stays where it was, so a click
// in the bar is not a jump to line 0.
point_place :: proc(a: ^App, cx, cy: int, extend := false) {
    s := active(a)
    snap, d, ok := reading(a, s)
    if !ok {
        return
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    r := active_rect(a)
    p, _, hit := view.locate(&snap.text, d, s.view, r.x, r.y, r.w, r.h, cx, cy)
    if !hit {
        return
    }
    doc := store.store_doc(&a.docs, s.doc)
    txt.doc_collapse_to_primary(doc)
    txt.doc_set_head(doc, p, extend)
    point_sync(a)
}

point_drag :: proc(a: ^App, cx, cy: int) {
    a.hover = {}
    point_place(a, cx, cy, true)
}

// What a double-click selects, at the document's own granularity (§5): a browser takes the row,
// an editor the word under point.
select_expand :: proc(a: ^App) {
    s := active(a)
    snap, d, ok := reading(a, s)
    if !ok {
        return
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    doc := store.store_doc(&a.docs, s.doc)
    at := doc.cursors[doc.primary].head
    switch d.selection {
    case .Char:
        txt.doc_select_word(doc, at)
    case .Line:
        txt.doc_select_line(doc, at.line)
    case .None:
        return
    }
    point_sync(a)
}

// Selecting is not editing: a listing has a selection too, and `:sel` reads it.
@(private = "file")
select_all :: proc(a: ^App) {
    s := active(a)
    doc := s != nil ? store.store_doc(&a.docs, s.doc) : nil
    if doc == nil {
        return
    }
    txt.doc_select_all(doc)
    point_sync(a)
}

scroll_by :: proc(a: ^App, lines: int) {
    s := active(a)
    if s == nil {
        return
    }
    snap := store.store_snapshot(&a.docs, s.doc)
    if snap == nil {
        return
    }
    defer txt.snapshot_release(snap)
    view.scroll(&s.view, &snap.text, lines)
}

// Does this line act on the span the pointer is over — the field itself, or a wider one it
// sits inside. Containment is what lets hover offer the NAME for a line that acts on the PATH.
@(private = "file")
line_covers :: proc(d: ^desc.Descriptor, template: string, line, lo, hi: int) -> bool {
    rest := template
    for {
        _, name, tail, found := hole_next(rest)
        if !found {
            return false
        }
        if a, b, named := desc.field_span(d, line, name); named && a <= lo && b >= hi {
            return true
        }
        rest = tail
    }
}

// --- hover (§8) ---

// Ask the bind table whether a click here would do anything, and underline the field it would
// act on. Three consequences of "a click is a chord", and no surface writes a line of any of
// them.
hover_update :: proc(a: ^App, cx, cy: int) {
    was := a.hover
    a.hover = {}
    defer if a.hover != was && a.window != nil {
        glfw.SetCursor(a.window, a.hover.on ? a.hand : nil)
    }

    s := ring_focused(&a.ring)
    snap, d, ok := reading(a, s)
    if !ok {
        return
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    b := a.body
    p, field, hit := view.locate(&snap.text, d, s.view, b.x, b.y, b.w, b.h, cx, cy)
    if !hit || field == "" {
        return
    }
    bind, _, bound := input.bind_lookup(a.binds[:], {input.mouse_code(.Click), {}}, d.ctx, d.kind)
    if !bound {
        return
    }
    // A verb acts on point and needs no field; only a line has a hole to fill.
    line, is_line := bind.target.(input.Bind_Line)
    if !is_line {
        return
    }
    lo, hi, named := desc.field_span(d, p.line, field)
    if named && line_covers(d, line.text, p.line, lo, hi) {
        a.hover = {p.line, lo, hi, true}
    }
}

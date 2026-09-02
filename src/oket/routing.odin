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

// The focused document names its own context, and the descriptor is where it says so (§5). An
// empty store leaves only Global. The Kind arrives with registered kinds at stage 7.
bind_ctx :: proc(a: ^App) -> (input.Bind_Ctx, input.Kind) {
    d := store.store_descriptor(&a.docs, a.id)
    if d == nil {
        return .Global, 0
    }
    defer desc.release(d)
    return d.ctx, 0
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
                                       context.temp_allocator)
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
        return // the miss rule needs a surface with its own key job; stage 6
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
    if motion, moves := motion_of(cmd); moves {
        point_move(a, motion, extend)
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
    case .Select_Expand:
        select_expand(a)
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

// The line arm of a bind (§8): holes filled from point, then run or staged as the file said.
// The command line arrives at stage 5, so for now the filled line is shown rather than run —
// what a hole resolves to is the half this stage is proving.
@(private = "file")
bind_line_fire :: proc(a: ^App, line: input.Bind_Line) {
    text, ok := bind_expand(a, line.text)
    if !ok {
        return
    }
    message_set(a, fmt.tprintf("%s: %s", line.stage ? "stage" : "exec", text))
}

// Fills every `<name>` from the fields of the line point is on (§5). A name the document does
// not carry stops the line rather than running one with a hole still in it.
bind_expand :: proc(a: ^App, template: string) -> (string, bool) {
    snap, d, ok := reading(a)
    if !ok {
        return "", false
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)

    b := strings.builder_make(context.temp_allocator)
    rest := template
    for {
        lo := strings.index_byte(rest, '<')
        if lo < 0 {
            break
        }
        hi := strings.index_byte(rest[lo:], '>')
        if hi < 0 {
            break
        }
        strings.write_string(&b, rest[:lo])
        value, got := view.field_text(&snap.text, d, a.view.point.head.line,
                                      rest[lo + 1:lo + hi])
        if !got {
            return "", false
        }
        strings.write_string(&b, value)
        rest = rest[lo + hi + 1:]
    }
    strings.write_string(&b, rest)
    return strings.to_string(b), true
}

// --- point and the viewport ---

// The caret lives in the document and nowhere else; view.View carries a copy so the frame can
// render it. This is the one place that copy is made.
point_sync :: proc(a: ^App) {
    if doc := store.store_doc(&a.docs, a.id); doc != nil {
        a.view.point = doc.cursors[doc.primary]
    }
}

// The read pair every event wants: the frozen text and the descriptor its generation named. The
// caller releases both.
@(private = "file")
reading :: proc(a: ^App) -> (^txt.Snapshot, ^desc.Descriptor, bool) {
    snap := store.store_snapshot(&a.docs, a.id)
    if snap == nil {
        return nil, nil, false
    }
    return snap, store.store_descriptor(&a.docs, a.id), true
}

point_move :: proc(a: ^App, motion: txt.Motion, extend: bool) {
    doc := store.store_doc(&a.docs, a.id)
    if doc == nil {
        return
    }
    txt.doc_move(doc, motion, extend)
    point_sync(a)
    view.follow(&a.view, a.body.h)
}

// Where a click lands. Outside the document's rectangle the caret stays where it was, so a click
// in the bar is not a jump to line 0.
point_place :: proc(a: ^App, cx, cy: int, extend := false) {
    snap, d, ok := reading(a)
    if !ok {
        return
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    p, _, hit := view.locate(&snap.text, d, a.view, a.body.x, a.body.y, a.body.w, a.body.h, cx, cy)
    if !hit {
        return
    }
    doc := store.store_doc(&a.docs, a.id)
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
    snap, d, ok := reading(a)
    if !ok {
        return
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    doc := store.store_doc(&a.docs, a.id)
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

scroll_by :: proc(a: ^App, lines: int) {
    snap := store.store_snapshot(&a.docs, a.id)
    if snap == nil {
        return
    }
    defer txt.snapshot_release(snap)
    view.scroll(&a.view, &snap.text, lines)
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

    snap, d, ok := reading(a)
    if !ok {
        return
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    p, field, hit := view.locate(&snap.text, d, a.view, a.body.x, a.body.y, a.body.w, a.body.h,
                                 cx, cy)
    if !hit || field == "" {
        return
    }
    b, _, bound := input.bind_lookup(a.binds[:], {input.mouse_code(.Click), {}}, d.ctx, 0)
    if !bound {
        return
    }
    // A verb acts on point and needs no field; only a line has a hole to fill, and the field it
    // names is the one worth offering.
    line, is_line := b.target.(input.Bind_Line)
    if !is_line || !strings.contains(line.text, fmt.tprintf("<%s>", field)) {
        return
    }
    lo, hi, named := desc.field_span(d, p.line, field)
    if named {
        a.hover = {p.line, lo, hi, true}
    }
}

package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
    return cl_active(a) ? &a.cl.slot : ring_focused(a)
}

// That document itself; nil for an empty ring or a closed doc.
@(private = "file")
active_doc :: proc(a: ^App) -> ^txt.Doc {
    s := active(a)
    return s != nil ? store.store_doc(&a.docs, s.doc) : nil
}

// Where that document was drawn, for a click. The line's row while it is open, the focused
// panel's body otherwise, so a click never lands in a document the keys are not aimed at.
active_rect :: proc(a: ^App) -> Rect {
    return cl_active(a) ? a.bar : panel_focused(a).body
}

// And WHOSE cells that rectangle is in (§7): the chrome's while the line is open, the focused
// panel's otherwise. A click from the other lattice is a different grid's numbers, and placing
// it against this rectangle would move a caret for a click beside it. -1 is the chrome.
active_panel :: proc(a: ^App) -> int {
    return cl_active(a) ? -1 : a.focus
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
    // The armed picker is a context of its own (PANELS.md §6), entered at ARM time and not at
    // the press of the key it holds: left and right choose a panel for exactly as long as the
    // gesture lasts, and nothing else is shadowed.
    if _, armed := a.pending.(input.Pending_Pick); armed {
        return .Pick, 0
    }
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
        if chord == {esc, {}, 0} {
            input.pending_set(&a.pending)
            return true
        }
        ctx, kind := bind_ctx(a)
        answer := input.describe_chord(a.binds[:], chord, ctx, key_layout_name, names(a), kind,
                                       context.temp_allocator)
        message_set(a, answer)
        input.pending_set(&a.pending)
        return true
    }
    return false
}

// Escape with more than one caret up over the focused document. False with one, so Escape keeps
// every other meaning it has and there is still a key that quits. Describe never answers for
// Escape (pending_take cancels on it instead), so the BAR is what says a trail is up and how to
// put it down — see bar_text.
@(private = "file")
esc_collapses :: proc(a: ^App, chord: input.Chord) -> bool {
    esc, _ := input.key_code("ESC")
    if chord != (input.Chord{esc, {}, 0}) {
        return false
    }
    doc := active_doc(a)
    return doc != nil && len(doc.cursors) > 1
}

handle_chord :: proc(a: ^App, chord: input.Chord, repeat := false) {
    if pending_take(a, chord) {
        return
    }
    // A repeat of the chord that armed the picker is the key never having come up, and the
    // `[pick]` row it resolves to makes a panel (§6). One press, one panel.
    if repeat && pick_armed_by(a, chord) {
        return
    }
    message_set(a, "")
    // A trail owns Escape ahead of every row that claims the key — quit, surface.send and the
    // command line's own close alike (VIEWS.md §4). Behind an armed picker, which owns the
    // keystroke outright, and not a row itself: the condition is the trail, and a bind table has
    // no way to say `while N > 1`.
    if _, armed := a.pending.(input.Pending_Pick); !armed && esc_collapses(a, chord) {
        cursor_command(a, .Cursor_Collapse)
        return
    }
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
        bind_line_fire(a, chord, line)
        return
    }
    if slot, registered := b.target.(input.Slot); registered {
        plug_command(a, slot, "")
        return
    }
    cmd, _ := input.bind_command(b) // the line and slot arms returned, so a Command is all that is left
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
    if cursor_command(a, cmd) {
        return
    }
    #partial switch cmd {
    case .Quit:
        a.quit = true
    case .Describe_Key:
        input.pending_set(&a.pending, input.Pending_Describe{})
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
    case .Save:
        dump_doc(a)
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
        ring_alt(a)
    case .Ring_Alt_Lane:
        ring_alt_lane(a)
    case .Ring_Close:
        ring_close(a, ring_slot(a))
    case .Ring_System:
        sys_slot(a) // alt+0 opens N# if nothing has needed it yet
        ring_show_system(a)
    case .Panel_Open:
        panel_open(a)
    case .Panel_Close:
        panel_close(a)
    case .Panel_Next:
        panel_step(a, +1)
    case .Panel_Prev:
        panel_step(a, -1)
    case .Panel_Move_Left:
        panel_shift(a, -1)
    case .Panel_Move_Right:
        panel_shift(a, +1)
    case .Pick_Left:
        pick_step(a, -1)
    case .Pick_Right:
        pick_step(a, +1)
    case .Pick_Cancel:
        pick_drop(a)
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

// Which verbs act on the text under point. Split from the bodies below so the refusal is
// decided in one place, and so a verb that only moves a selection is not caught by it.
//
// Every one of them is a ROW: named, describable and rebindable, which is what makes them the
// kernel's to answer where a typed rune is not (see text_input). They are storage over cursors
// and no document's policy, so a plugin's buffer gets them with no code — and a plugin that
// wants its own indent rule shadows the row for its kind, which is what plugins/edit does.
@(private = "file")
writes :: proc(cmd: input.Command) -> bool {
    #partial switch cmd {
    case .Delete_Back, .Delete_Forward, .Delete_Word_Back, .Delete_Word_Forward, .Tab,
         .Newline, .Undo, .Redo:
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
    case .Newline:
        txt.doc_newline(doc)
    // Undo is the kernel's, so ctrl+z reaches a formatter's splice and a plugin writes no undo
    // code (§7). `editable` is the gate until the descriptor grows `undo: kernel | none` (§5):
    // a document that takes no typing has nothing of the user's in it to take back.
    case .Undo:
        txt.doc_undo(doc)
    case .Redo:
        txt.doc_redo(doc)
    }
    point_sync(a)
    return true
}

// Which verbs place a caret rather than move or write one. Split from the bodies below for the
// same reason `writes` is: the refusal is decided once, and a verb that only grows the set is
// not caught by the typing gate.
@(private = "file")
places :: proc(cmd: input.Command) -> bool {
    #partial switch cmd {
    case .Cursor_Add, .Cursor_Add_Below, .Cursor_Add_Above, .Cursor_Add_Next, .Cursor_Add_All,
         .Cursor_Split, .Cursor_Collapse:
        return true
    }
    return false
}

// The placement verbs (VIEWS.md §4). Selecting is not editing, so a listing gets them with no
// `editable` gate, the same way select.all and select.expand already reach one.
@(private = "file")
cursor_command :: proc(a: ^App, cmd: input.Command) -> bool {
    if !places(cmd) {
        return false
    }
    doc := active_doc(a)
    if doc == nil {
        return true
    }
    #partial switch cmd {
    case .Cursor_Add:
        cursor_add(a, doc)
    case .Cursor_Add_Below:
        txt.doc_add_cursor_line(doc, +1, views_hidden(a, active(a).doc))
    case .Cursor_Add_Above:
        txt.doc_add_cursor_line(doc, -1, views_hidden(a, active(a).doc))
    case .Cursor_Add_Next:
        txt.doc_add_next_match(doc)
    case .Cursor_Add_All:
        txt.doc_add_all_matches(doc)
    case .Cursor_Split:
        txt.doc_split_lines(doc, a.config.split)
    case .Cursor_Collapse:
        txt.doc_collapse_to_primary(doc)
    }
    point_sync(a)
    return true
}

// alt+click. The kernel's point move was skipped for this chord (point_press), so the carets
// already up are still up and the cell the pointer is over is where the new one goes.
@(private = "file")
cursor_add :: proc(a: ^App, doc: ^txt.Doc) {
    p, hit := point_at(a, a.mouse.at.x, a.mouse.at.y)
    if !hit {
        return
    }
    txt.doc_add_cursor(doc, p)
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
//
// THE KERNEL INTERPRETS ONE FOR THE DOCUMENTS IT IMPLEMENTS, AND FOR NOBODY ELSE (§7). A rune
// is the one input the bind table never sees, so a kernel self-insert would be an editing
// policy that no row names, that describe cannot answer for and that nothing can rebind — and
// what typing MEANS is exactly where editors disagree. So the command line takes its own
// typing, and every other document is handed the rune: the terminal writes it to its PTY, a
// plugin's document gets an `event`, and the descriptor is what says which.
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
    s, d := active_desc(a)
    if d == nil {
        return
    }
    defer desc.release(d)
    // `editable` is a document that takes typing; `raw` is one that takes everything, bound or
    // not. Either way the rune goes to its owner, and neither is a document the kernel edits.
    if !d.editable && d.input != .Raw {
        return
    }
    if tm := term_of(a, s.doc); tm != nil {
        term_text(tm, r)
        return
    }
    plug_type(a, s.doc, r)
}

// The focused document's own job, when its descriptor says input reaches it (§5). A terminal
// has a PTY, a plugin's document has an `event`, and the descriptor is what says either — the
// funnel never learns which kind it is looking at. False is not a refusal to report: the caller
// decides, because a miss and a bound row answer it differently.
surface_send :: proc(a: ^App, chord: input.Chord) -> bool {
    s, raw := raw_target(a)
    if !raw {
        return false
    }
    if tm := term_of(a, s.doc); tm != nil {
        term_send(a, tm, chord)
        return true
    }
    return plug_send(a, s.doc, chord)
}

@(private = "file")
raw_target :: proc(a: ^App) -> (^Slot, bool) {
    s, d := active_desc(a)
    if d == nil {
        return nil, false
    }
    defer desc.release(d)
    return s, d.input == .Raw
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

// The line arm of a bind (§8): holes filled from point, then run, staged or armed as the file
// said. `exec` runs it, `stage` puts it in the command line for aiming, `pick` waits for the
// chord's held key to come up (PANELS.md §6) — those three words are the whole grammar, and
// they are what makes Enter and Shift+Enter two rows over one value rather than two code paths
// in a plugin.
@(private = "file")
bind_line_fire :: proc(a: ^App, chord: input.Chord, line: input.Bind_Line) {
    if line.mode == .Pick {
        pick_arm(a, chord, line)
        return
    }
    text, ok := bind_expand(a, line.text)
    if !ok {
        return
    }
    if line.mode == .Stage {
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
    // A line with no hole needs no point. `:width 100 50` is the whole line already, and a
    // panel standing on nothing must not swallow the chord (§8).
    if !strings.contains(template, "<") {
        return strings.clone(template, context.temp_allocator), true
    }
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

// `file.dump` (§8): the focused document's bytes, beside the binary, under a name derived from
// what it is called. The recovery floor and nothing more — writing a buffer BACK to its file is
// the opener's, because what a file is on disk is what the opener knew and the kernel does not.
dump_doc :: proc(a: ^App) -> bool {
    s := ring_focused(a)
    doc := s != nil ? store.store_doc(&a.docs, s.doc) : nil
    if doc == nil {
        message_set(a, "file.dump: nothing is focused")
        return false
    }
    if a.home == "" {
        message_set(a, "file.dump: there is nowhere beside the binary to write")
        return false
    }
    name := filepath.base(doc_title(a, s.doc))
    if name == "" || name == "." || name == "/" {
        name = "document"
    }
    path, _ := filepath.join({a.home, fmt.tprintf("%s.dump", name)}, context.temp_allocator)
    text := txt.doc_string(doc, context.temp_allocator)
    if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
        message_set(a, fmt.tprintf("file.dump: cannot write %s: %v", path, err))
        return false
    }
    message_set(a, fmt.tprintf("dumped %d bytes to %s", len(text), path))
    return true
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

// Writes land at one point (§6), and the caret the frame draws catches up in the same breath.
// Called after every drain — the frame's, and the one behind each plugin call — so a document
// somebody else moved is on screen, and under a live caret, the moment it lands.
// The return is a view stage's latch (VIEWS.md §5), which is the one thing no keystroke and no
// reader thread will wake. Every other caller ignores it: only the frame loop can act on it.
docs_settle :: proc(a: ^App) -> (latched: bool) {
    applied, _ := store.store_drain(&a.docs)
    // Before the early return: a splice written straight through `store_doc` moves a document
    // with no transaction behind it, and its journal still has to be flushed (§10).
    journal_sync(a)
    if applied != 0 {
        point_sync(a)
    }
    // The view pipeline, after the drain and after the carets it moved: a stage reads both, and
    // one built before them would draw the frame before. Its own generation cache decides
    // whether anything is rebuilt, so a settled document costs a map lookup.
    latched = views_settle(a)
    if applied == 0 {
        return
    }
    s := active(a)
    d := s != nil ? store.store_descriptor(&a.docs, s.doc) : nil
    if d == nil {
        return
    }
    defer desc.release(d)
    // A tail document decides its own top by what is on screen (§11), and yanking it to the
    // caret would be the attached/detached flag that field exists to not need.
    if d.follow != .Tail {
        snap := store.store_snapshot(&a.docs, s.doc)
        if snap == nil {
            return
        }
        defer txt.snapshot_release(snap)
        t, dv := views_text(a, s.doc, &snap.text)
        view.follow(&s.view, active_rect(a).h, t, dv)
    }
    return
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
    // §7's export to the pipeline, and the whole of it: the runs of the original no cell stands
    // for. `txt` takes a slice and stays pure — it never learns what a fold is.
    txt.doc_move(doc, motion, extend, hidden = views_hidden(a, s.doc))
    point_sync(a)
    snap := store.store_snapshot(&a.docs, s.doc)
    if snap == nil {
        return
    }
    defer txt.snapshot_release(snap)
    t, dv := views_text(a, s.doc, &snap.text)
    view.follow(&s.view, active_rect(a).h, t, dv)
}

// Which document byte a cell is over. Outside the document's rectangle nothing is, so a click in
// the bar is not a jump to line 0.
@(private = "file")
point_at :: proc(a: ^App, cx, cy: int) -> (txt.Pos, bool) {
    s := active(a)
    snap, d, ok := reading(a, s)
    if !ok {
        return {}, false
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    r := active_rect(a)
    t, dv := views_text(a, s.doc, &snap.text)
    p, _, hit := view.locate(t, d, s.view, r.x, r.y, r.w, r.h, cx, cy, dv)
    return p, hit
}

// Where a click lands: one caret, there. A trail goes down, which is what makes a plain click
// the way out of one that needs no key.
point_place :: proc(a: ^App, cx, cy: int, extend := false) {
    p, hit := point_at(a, cx, cy)
    if !hit {
        return
    }
    doc := active_doc(a)
    txt.doc_collapse_to_primary(doc)
    txt.doc_set_head(doc, p, extend)
    point_sync(a)
}

// The point move a button PRESS makes before its release dispatches a chord (§8). WHICH move is
// the row's to decide: a chord naming a verb that places its own point gets none, so alt+click
// still has the trail to add to by the time cursor.add runs.
point_press :: proc(a: ^App, m: input.Mouse, mods: input.Mods, cx, cy: int) {
    ctx, kind := bind_ctx(a)
    if b, _, ok := input.bind_lookup(a.binds[:], {input.mouse_code(m), mods, 0}, ctx, kind); ok {
        if cmd, named := input.bind_command(b); named && input.command_places_point(cmd) {
            return
        }
    }
    point_place(a, cx, cy)
}

point_drag :: proc(a: ^App, cx, cy: int) {
    hover_clear(a)
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
    doc := active_doc(a)
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
    t, _ := views_text(a, s.doc, &snap.text) // `top` is a line of the DRAWN document
    view.scroll(&s.view, t, lines)
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

// The command line a mouse chord would run here, if it runs one. A verb acts on point and needs
// no field, so only a line has a hole for hover to underline.
@(private = "file")
click_line :: proc(a: ^App, d: ^desc.Descriptor, button: input.Mouse) -> (input.Bind_Line, bool) {
    chord := input.Chord{input.mouse_code(button), {}, 0}
    bind, _, bound := input.bind_lookup(a.binds[:], chord, d.ctx, d.kind)
    if !bound {
        return {}, false
    }
    line, is_line := bind.target.(input.Bind_Line)
    return line, is_line
}

// Either button chord, because the question is "would clicking here do something" and a
// document whose single click only moves point may still answer the second one — which is
// what a listing you can also type into wants (the row navigates, the click lands a caret).
@(private = "file")
hover_line :: proc(a: ^App, d: ^desc.Descriptor) -> (input.Bind_Line, bool) {
    if line, is_line := click_line(a, d, .Click); is_line {
        return line, true
    }
    return click_line(a, d, .Double_Click)
}

// Ask the bind table whether a click here would do anything, and underline the field it would
// act on. Three consequences of "a click is a chord", and no surface writes a line of any of
// them. The panel is the POINTER'S and not the focused one's, because that is where the
// underline goes; leaving every panel puts it away.
hover_update :: proc(a: ^App, panel, cx, cy: int) {
    was := hover_on(a)
    hover_clear(a)
    defer if hover_on(a) != was && a.window != nil {
        glfw.SetCursor(a.window, hover_on(a) ? a.hand : nil)
    }
    pn := panel_get(a, panel)
    if pn == nil {
        return
    }

    s := panel_slot(a, pn)
    snap, d, ok := reading(a, s)
    if !ok {
        return
    }
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    b := pn.body
    t, dv := views_text(a, s.doc, &snap.text)
    p, field, hit := view.locate(t, d, s.view, b.x, b.y, b.w, b.h, cx, cy, dv)
    if !hit || field == "" {
        return
    }
    line, is_line := hover_line(a, d)
    if !is_line {
        return
    }
    lo, hi, named := desc.field_span(d, p.line, field)
    if named && line_covers(d, line.text, p.line, lo, hi) {
        pn.hover = {p.line, lo, hi, true}
    }
}

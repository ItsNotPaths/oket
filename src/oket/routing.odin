package main

import "lues:lues"
import "lues:pt"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import "../desc"
import "../gfx"
import "../input"
import "../store"
import "../txt"
import "../view"
import "../cl"

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
    return s != nil ? store.store_doc(a.docs, s.doc) : nil
}

// Where that document was drawn, for a click. The line's row while it is open, the focused
// panel's body otherwise, so a click never lands in a document the keys are not aimed at.
active_rect :: proc(a: ^App) -> Cells {
    return cl_active(a) ? a.bar : panel_focused(a).body
}

// And WHOSE cells that rectangle is in (§7): the ground's while the line is open, the focused
// panel's otherwise. A click from the other lattice is a different grid's numbers, and placing
// it against this rectangle would move a caret for a click beside it. -1 is the ground.
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
    return s, store.store_descriptor(a.docs, s.doc)
}

// The sections a chord walks over the focused document, from its kind (§5). The open command
// line is `[cmdline]`. An empty store leaves only global.
bind_path :: proc(a: ^App) -> (path: []Section, send: bool) {
    if cl_active(a) {
        return section_path(a, SEC_CMDLINE)
    }
    _, d := active_desc(a)
    if d == nil {
        return section_path(a, SEC_GLOBAL)
    }
    defer desc.release(d)
    return section_path(a, kind_section(a, d.kind))
}

// A capture owns the keystroke: Escape clears it at any depth, anything else is the input it was
// waiting for.
@(private = "file")
pending_take :: proc(a: ^App, chord: input.Chord) -> bool {
    esc, _ := input.key_code("ESC")
    #partial switch _ in a.pending {
    case input.Pending_Describe:
        if chord == {esc, {}} {
            input.pending_set(&a.pending)
            return true
        }
        path, send := bind_path(a)
        answer := input.describe_chord(a.binds[:], chord, path, send, key_layout_name, names(a),
                                       context.temp_allocator)
        message_set(a, answer)
        input.pending_set(&a.pending)
        return true
    case input.Pending_Prefix:
        return prefix_take(a, chord)
    case input.Pending_Menu:
        return menu_take(a, chord)
    }
    return false
}

// Arms a primer, if this chord is one. The label is built here because the table cannot change
// while a primer is up, and it is owned the way an armed pick owns its line. It POINTS at the
// help chord rather than listing the children: the menubar that chord opens is where they are.
@(private = "file")
prefix_arm :: proc(a: ^App, chord: input.Chord, path: []Section) -> bool {
    if !input.bind_primes(a.binds[:], chord, path) {
        return false
    }
    spelling := input.chord_format(chord, key_layout_name, context.temp_allocator)
    help := input.chord_format(prefix_help(chord), key_layout_name, context.temp_allocator)
    input.pending_set(&a.pending, input.Pending_Prefix {
        chord = chord,
        label = fmt.aprintf("%s: %s lists what follows it, esc cancels", spelling, help),
    })
    return true
}

// The chord that opens the menu under this primer: the help key carrying the PRIMER'S OWN
// modifier, so the hand already holding it drops a thumb (MENU.md §5, and PREFIX_HELP's note).
@(private = "file")
prefix_help :: proc(prefix: input.Chord) -> input.Chord {
    code, _ := input.key_code(input.PREFIX_HELP)
    return {code, prefix.mods}
}

// The two keys a primer reserves, and then the outcomes below. Both reserved chords are answered
// here rather than in the resolve, because both are about the PRIMER and neither is a child.
@(private = "file")
prefix_take :: proc(a: ^App, chord: input.Chord) -> bool {
    p, _ := a.pending.(input.Pending_Prefix)
    esc, _ := input.key_code("ESC")
    // Escape is unmodified and would fall through to quit, so it cancels ahead of the rule
    // below. The help chord is the one other key the primer reserves.
    if chord == (input.Chord{esc, {}}) {
        input.pending_set(&a.pending)
        return true
    }
    if chord == prefix_help(p.chord) {
        menu_open(a, p.chord) // the write that replaces this pending is what frees its label
        return true
    }
    prefix := p.chord
    input.pending_set(&a.pending)
    return prefix_resolve(a, chord, prefix)
}

// The three outcomes of a chord under a primer (§4.2).
//
// An UNMODIFIED chord is never part of a sequence — structurally, not by timing — so it answers
// false, and the caller lets the key do exactly what it always did. That transparency is the
// whole difference between this and Emacs. A modified chord that no child claims is ABSORBED and
// reported: dispatching it as itself would fire an unrelated verb because a sequence did not
// exist, which is what describe exists to prevent.
//
// Shared with the menubar, because a menu opened on a primer's popout is still under that primer
// and a chord it does not claim was typed at those children (MENU.md §5).
prefix_resolve :: proc(a: ^App, chord, prefix: input.Chord) -> bool {
    if chord.mods == {} || prefix == (input.Chord{}) {
        return false
    }
    path, _ := bind_path(a)
    if b, ok := input.bind_lookup(a.binds[:], chord, path, prefix); ok {
        bind_dispatch(a, chord, b)
        return true
    }
    message_set(a, fmt.tprintf("%s is unbound", input.chord_pair_format(
        prefix, chord, key_layout_name, context.temp_allocator)))
    return true
}

// Escape with more than one caret up over the focused document. False with one, so Escape keeps
// every other meaning it has and there is still a key that quits. Describe never answers for
// Escape (pending_take cancels on it instead), so the BAR is what says a trail is up and how to
// put it down — see bar_text.
@(private = "file")
esc_collapses :: proc(a: ^App, chord: input.Chord) -> bool {
    esc, _ := input.key_code("ESC")
    if chord != (input.Chord{esc, {}}) {
        return false
    }
    doc := active_doc(a)
    return doc != nil && len(doc.cursors) > 1
}

handle_chord :: proc(a: ^App, chord: input.Chord) {
    if pending_take(a, chord) {
        return
    }
    message_set(a, "")
    // A trail owns Escape ahead of every row that claims the key — quit, surface.send and the
    // command line's own close alike (VIEWS.md §4). Not a row itself: the condition is the
    // trail, and a bind table has no way to say `while N > 1`.
    if esc_collapses(a, chord) {
        cursor_command(a, .Cursor_Collapse)
        return
    }
    path, send := bind_path(a)
    b, ok := input.bind_lookup(a.binds[:], chord, path)
    if !ok {
        // A chord no row claims may still be a PRIMER, which is a row's prefix and never a row
        // of its own (§4.1). Asked after the lookup, so a chord that already runs something
        // keeps running it and the clash is what the home page reports. Never over a pending:
        // arming would close the command line.
        if a.pending == nil && prefix_arm(a, chord, path) {
            return
        }
        // The miss rule (§8, §14): a section that lists `send` forwards to its document's job,
        // and everything else stays quiet. A chord that IS bound and does nothing is the thing
        // that section exists to prevent; an unbound one is just an unbound one.
        if send {
            surface_send(a, chord)
        }
        return
    }
    bind_dispatch(a, chord, b)
}

// A resolved row, run. Split from handle_chord so a child reached under a primer takes exactly
// the path its plain sibling takes (§4.2) — and so a row PRESSED in the menu takes it too, which
// is the whole of "the menu does what typing it does" (MENU.md §1).
bind_dispatch :: proc(a: ^App, chord: input.Chord, b: input.Bind) {
    cmd, named := line_command(b.line)
    // The line answers four chords for itself; everything else acts on it because `active`
    // says it is the document now.
    if named && cl_active(a) && cl_take(a, cmd) {
        return
    }
    // `surface.send` forwards the CHORD, which no typed line can carry. A row named it, so a
    // document with no job of its own has to say so: a bound chord that quietly does nothing is
    // the one thing §8 exists to prevent. The miss path above stays silent.
    if named && cmd == .Surface_Send {
        if !surface_send(a, chord) {
            message_set(a, "this document has no job of its own")
        }
        return
    }
    line_run(a, b.line)
}

Command_Arg :: enum {
    None,
    Slot,
    Extend,
}

// What a verb takes when it is typed: the slot alt+N carries, or the shift a motion carries.
command_arg :: proc(cmd: Command) -> Command_Arg {
    if cmd == .Ring_Goto {
        return .Slot
    }
    if _, moves := motion_of(cmd); moves {
        return .Extend
    }
    return .None
}

command_usage :: proc(cmd: Command) -> string {
    name := COMMANDS[cmd].name
    switch command_arg(cmd) {
    case .Slot:
        return fmt.tprintf(":%s <N>", name)
    case .Extend:
        return fmt.tprintf(":%s [extend]", name)
    case .None:
    }
    return fmt.tprintf(":%s", name)
}

// A verb, run. Keyed on the enum, so a keystroke never goes through cl.parse and never resets
// a chain. `n` is the slot for ring.goto; `extend` is for motions.
command_run :: proc(a: ^App, cmd: Command, n: int, extend: bool) {
    // A cycle only means anything straight after a paste, so every other verb puts the mark
    // down. That is what keeps ctrl+shift+v config rather than a mode.
    if cmd != .Paste && cmd != .Paste_Cycle {
        a.paste.live = false
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
        scroll_by(a, -a.config.wheel)
    case .View_Scroll_Down:
        scroll_by(a, +a.config.wheel)
    case .View_Page_Up:
        scroll_by(a, -max(active_rect(a).h - 1, 1))
    case .View_Page_Down:
        scroll_by(a, +max(active_rect(a).h - 1, 1))
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
    case .Copy:
        copy_doc(a)
    case .Ring_Goto:
        ring_open(a, n)
    case .Ring_Alt:
        ring_alt(a)
    case .Ring_Alt_Lane:
        ring_alt_lane(a)
    case .Ring_Close:
        ring_close(a, ring_slot(a))
    case .Ring_Zero:
        sys_slot(a) // alt+0 opens N0 if nothing has needed it yet
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
    case .CL_Open:
        cl_show(a)
    case .CL_Sigil:
        cl_show(a, ":")
    case .Menu_Open:
        menu_open(a)
    case .Search_Next:
        search_step(a, .Forward)
    case .Search_Prev:
        search_step(a, .Back)
    case .Jump_Back:
        jump_back(a)
    case .Jump_Forward:
        jump_forward(a)
    case .Font_Bigger:
        font_zoom(a, +1)
    case .Font_Smaller:
        font_zoom(a, -1)
    case .Font_Reset:
        font_reset(a)
    case:
        // A bound chord that does nothing at all is the one thing §8 exists to prevent, so a
        // verb whose stage has not landed says so rather than going quiet.
        //
        // Nothing reaches this today — every name in COMMANDS dispatches above. The arm stays
        // as the net for the next verb named before it is built.
        message_set(a, fmt.tprintf("%s is not built yet", COMMANDS[cmd].name))
    }
}

// Which range a kill verb takes, in the shape motion_of already answers.
@(private = "file")
kill_of :: proc(cmd: Command) -> (txt.Kill, bool) {
    #partial switch cmd {
    case .Kill_Line:
        return .To_Line_End, true
    case .Kill_Whole_Line:
        return .Whole_Line, true
    case .Kill_To_Line_Start:
        return .To_Line_Start, true
    }
    return {}, false
}

@(private = "file")
motion_of :: proc(cmd: Command) -> (txt.Motion, bool) {
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
    case .Para_Up:
        return .Para_Up, true
    case .Para_Down:
        return .Para_Down, true
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
writes :: proc(cmd: Command) -> bool {
    #partial switch cmd {
    case .Delete_Back, .Delete_Forward, .Delete_Word_Back, .Delete_Word_Forward, .Tab,
         .Newline, .Undo, .Redo, .Cut, .Paste, .Paste_Cycle,
         .Kill_Line, .Kill_Whole_Line, .Kill_To_Line_Start:
        return true
    }
    return false
}

// The text ops, over whatever `active` names: the command line serves its one row through the
// same code a document gets (§11). A document that does not take typing refuses, which is what
// stops a Backspace over a listing from eating the row it is standing on.
@(private = "file")
edit_command :: proc(a: ^App, cmd: Command) -> bool {
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
    // Paste reads the SYSTEM clipboard, which is what lets a browser's copy land here.
    case .Cut:
        cut_to_clip(a, doc)
    case .Paste:
        clip_sync(a)
        paste_and_mark(a, doc, 0)
    case .Paste_Cycle:
        paste_cycle(a, doc)
    // `doc_select_kill` can select nothing — ctrl+u at column 0, ctrl+k at the end of the last
    // line — and doc_cut reads an empty set as "no selection, take the line", hence the guard.
    case .Kill_Line, .Kill_Whole_Line, .Kill_To_Line_Start:
        k, _ := kill_of(cmd)
        txt.doc_select_kill(doc, k)
        if txt.doc_any_selection(doc) {
            cut_to_clip(a, doc)
        }
    // Undo is the kernel's, so ctrl+z reaches a formatter's splice and a plugin writes no undo
    // code (§7). `editable` is the gate until the descriptor grows `undo: kernel | none` (§5):
    // a document that takes no typing has nothing of the user's in it to take back.
    case .Undo:
        txt.doc_undo(doc, active_tab(a))
    case .Redo:
        txt.doc_redo(doc, active_tab(a))
    }
    point_sync(a)
    return true
}

// Which verbs place a caret rather than move or write one. Split from the bodies below for the
// same reason `writes` is: the refusal is decided once, and a verb that only grows the set is
// not caught by the typing gate.
@(private = "file")
places :: proc(cmd: Command) -> bool {
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
cursor_command :: proc(a: ^App, cmd: Command) -> bool {
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
        txt.doc_add_cursor_line(doc, +1, views_hidden(a, active(a).doc), active_tab(a))
    case .Cursor_Add_Above:
        txt.doc_add_cursor_line(doc, -1, views_hidden(a, active(a).doc), active_tab(a))
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
    return d.editable && !s.locked ? store.store_doc(a.docs, s.doc) : nil
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
    a.paste.live = false // typing is one of the "every other verb" the mark is put down for
    if cl_active(a) {
        doc := store.store_doc(a.docs, a.cl.doc)
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
    if s.locked || !d.editable && d.input != .Raw {
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
    return s, d.input == .Raw && !s.locked
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
    return d.mouse == .Events && !s.locked ? term_of(a, s.doc) : nil
}

// The `$o_` fields on the line point is on (§5), by the rule field_under reads them by.
vars_under_point :: proc(a: ^App) -> (vars: cl.Vars) {
    s := active(a)
    snap, d, ok := reading(a, s)
    if !ok {
        return
    }
    defer pt.snapshot_release(snap)
    defer desc.release(d)
    at := s.view.point.head
    fields := doc_fields(a, s.doc, &snap.text, at.line, at.line + 1)
    for name, i in cl.VARS {
        if f, got := desc.field_under(fields, at.line, at.col, name); got {
            vars[i] = strings.clone(f.value, context.temp_allocator) // outlives the snapshot
        }
    }
    return
}

// A line with its `$o_` names written in, for one that is shown or held before it runs. A name
// nothing here carries REPORTS rather than staying in the line unfilled (§14).
vars_fill :: proc(a: ^App, line: string) -> (string, bool) {
    text, missing, ok := cl.fill(vars_under_point(a), line)
    if !ok {
        vars_say_missing(a, missing)
    }
    return text, ok
}

vars_say_missing :: proc(a: ^App, name: string) {
    message_set(a, fmt.tprintf("nothing here has $o_%s", name))
}

// `file.dump` (§8): the focused document's bytes, into the state directory, under a name derived from
// what it is called. The recovery floor and nothing more — writing a buffer BACK to its file is
// the opener's, because what a file is on disk is what the opener knew and the kernel does not.
dump_doc :: proc(a: ^App) -> bool {
    s := ring_focused(a)
    doc := s != nil ? store.store_doc(a.docs, s.doc) : nil
    if doc == nil {
        message_set(a, "file.dump: nothing is focused")
        return false
    }
    if a.home.state == "" {
        message_set(a, "file.dump: there is nowhere to write it")
        return false
    }
    name := filepath.base(doc_title(a, s.doc))
    if name == "" || name == "." || name == "/" {
        name = "document"
    }
    path, _ := filepath.join({a.home.state, fmt.tprintf("%s.dump", name)}, context.temp_allocator)
    text := txt.doc_string(doc, context.temp_allocator)
    if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
        message_set(a, fmt.tprintf("file.dump: cannot write %s: %v", path, err))
        return false
    }
    message_set(a, fmt.tprintf("dumped %d bytes to %s", len(text), path))
    return true
}

// --- the clipboard ---

// The system clipboard is the copy path, both ways: what is copied here pastes into a browser,
// and a browser's copy pastes here. This is the SDL half of txt's doc_copy/doc_cut/doc_paste.
//
// The ring behind it exists for one verb. `edit.paste` always takes the clipboard, so the ring
// never stands between ctrl+v and what another program put there; `edit.paste_cycle` is the only
// reader of anything past the head.

CLIP_RING :: 16

// One entry: what went on the clipboard, and the same copy split one per caret. The clipboard
// can only carry the joined text, so the pieces are kept here or nowhere.
Clip :: struct {
    text:   string,   // owned
    pieces: []string, // owned; empty unless the copy was multi-caret
}

// Where the last paste landed, so a cycle can take it back and put the entry before it in its
// place. Not a mode: any other verb clears it, and the undo step is what a cycle undoes.
Paste_Mark :: struct {
    live: bool,
    at:   int, // the ring entry the text came from
    doc:  store.Id,
}

clip_head :: proc(a: ^App) -> Clip {
    return len(a.clips) > 0 ? a.clips[0] : Clip{}
}

// `a.clips[0]` is what oket last put on the clipboard. SDL answers with nothing when there is
// no window, and on X11 when the selection has been dropped — in both cases our own copy is
// still the truthful answer to "what did I copy", so it is the fallback rather than a cache.
clip_get :: proc(a: ^App) -> string {
    ctext := sdl.GetClipboardText() // owned; never nil
    defer sdl.free(rawptr(ctext))
    text := strings.clone(string(cstring(ctext)), context.temp_allocator)
    return text != "" ? text : clip_head(a).text
}

clip_set :: proc(a: ^App, text: string, pieces: []string = nil) {
    clip_push(a, text, pieces)
    sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}

@(private = "file")
clip_push :: proc(a: ^App, text: string, pieces: []string) {
    // Copying the same text twice REPLACES the head rather than making a neighbour of it: two
    // identical entries would give a cycle a step that changes nothing on screen.
    if len(a.clips) > 0 && a.clips[0].text == text {
        clip_destroy(&a.clips[0])
        ordered_remove(&a.clips, 0)
    }
    c := Clip {
        text = strings.clone(text),
    }
    // One piece is the joined string, so it says nothing a whole paste does not already say.
    if len(pieces) > 1 {
        out := make([]string, len(pieces))
        for p, i in pieces {
            out[i] = strings.clone(p)
        }
        c.pieces = out
    }
    inject_at(&a.clips, 0, c)
    for len(a.clips) > CLIP_RING {
        clip_destroy(&a.clips[len(a.clips) - 1])
        pop(&a.clips)
    }
}

// A copy made outside oket becomes the head before it is pasted, so the ring is a superset of
// what has been on the clipboard and a cycle starts from what was just pasted rather than from
// something older the user never saw.
@(private = "file")
clip_sync :: proc(a: ^App) {
    text := clip_get(a)
    if text == "" || text == clip_head(a).text {
        return // unchanged, and pushing would throw away the head's pieces
    }
    clip_push(a, text, nil) // a foreign copy is one string; nobody split it per caret
}

@(private = "file")
clip_destroy :: proc(c: ^Clip) {
    delete(c.text)
    for p in c.pieces {
        delete(p)
    }
    delete(c.pieces)
}

clips_free :: proc(a: ^App) {
    for &c in a.clips {
        clip_destroy(&c)
    }
    delete(a.clips)
    a.clips = nil
}

// One piece per caret when the entry has them and the count fits, the whole string otherwise:
// a foreign copy has no pieces, and a changed caret count cannot take one each. Returns whether
// the paste made its own undo step — a one-rune paste can coalesce into the typing before it,
// and one that did cannot be taken back on its own, which is what a cycle needs.
@(private = "file")
paste_at :: proc(a: ^App, doc: ^txt.Doc, at: int) -> bool {
    if at >= len(a.clips) {
        return false
    }
    c := a.clips[at]
    depth := txt.doc_steps_made(doc)
    if len(c.pieces) == len(doc.cursors) {
        txt.doc_paste_pieces(doc, c.pieces)
    } else {
        txt.doc_paste(doc, c.text)
    }
    return txt.doc_steps_made(doc) > depth
}

@(private = "file")
paste_and_mark :: proc(a: ^App, doc: ^txt.Doc, at: int) {
    a.paste = {live = paste_at(a, doc, at), at = at, doc = active(a).doc}
}

// The paste is undone and the entry before it put in its place, so repeating the chord walks
// the ring; undo restores the carets the paste moved.
@(private = "file")
paste_cycle :: proc(a: ^App, doc: ^txt.Doc) {
    if !a.paste.live || a.paste.doc != active(a).doc {
        message_set(a, "edit.paste_cycle: nothing was just pasted")
        return
    }
    if len(a.clips) < 2 {
        message_set(a, "edit.paste_cycle: the ring holds one entry")
        return
    }
    txt.doc_undo(doc)
    paste_and_mark(a, doc, (a.paste.at + 1) % len(a.clips))
}

// Copy then delete, so a cut or a killed range reaches the clipboard by the path a copied one
// does — the pairing txt/doc.odin describes.
@(private = "file")
cut_to_clip :: proc(a: ^App, doc: ^txt.Doc) {
    joined, pieces := txt.doc_copy(doc, context.temp_allocator)
    clip_set(a, joined, pieces)
    txt.doc_cut(doc)
}

// A read, so no `editable` gate, the same way select.all reaches a listing: copying a row out
// of a browser is not editing it.
@(private = "file")
copy_doc :: proc(a: ^App) {
    doc := active_doc(a)
    if doc == nil {
        return
    }
    joined, pieces := txt.doc_copy(doc, context.temp_allocator)
    clip_set(a, joined, pieces)
    message_set(a, "copied")
}

// --- point and the viewport ---

// The caret lives in the document and nowhere else; the slot's View carries a copy so the frame
// can render it. This is the one place that copy is made.
point_sync :: proc(a: ^App) {
    slot_sync(a, active(a))
}

slot_sync :: proc(a: ^App, s: ^Slot) {
    if s == nil {
        return
    }
    if doc := store.store_doc(a.docs, s.doc); doc != nil {
        s.view.point = doc.cursors[doc.primary]
    }
}

// Writes land at one point (§6), and the caret the frame draws catches up in the same breath.
// Called after every drain — the frame's, and the one behind each plugin call — so a document
// somebody else moved is on screen, and under a live caret, the moment it lands.
// The return is a view stage's latch (VIEWS.md §5), which is the one thing no keystroke and no
// reader thread will wake. Every other caller ignores it: only the frame loop can act on it.
docs_settle :: proc(a: ^App) -> (latched: bool) {
    lues.kernel_settle(a.kernel)
    // What landed here, and in every settle lues ran inside a dispatch since (hooks.drained).
    applied := a.settled
    a.settled = 0
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
    d := s != nil ? store.store_descriptor(a.docs, s.doc) : nil
    if d == nil {
        return
    }
    defer desc.release(d)
    // A tail document decides its own top by what is on screen (§11), and yanking it to the
    // caret would be the attached/detached flag that field exists to not need.
    if d.follow != .Tail {
        snap := store.store_snapshot(a.docs, s.doc)
        if snap == nil {
            return
        }
        defer pt.snapshot_release(snap)
        t, dv := views_text(a, s.doc, &snap.text)
        view.follow(&s.view, active_rect(a).h, t, dv)
    }
    return
}

// The read pair every event wants: the frozen text and the descriptor its generation named. The
// caller releases both.
reading :: proc(a: ^App, s: ^Slot) -> (^pt.Snapshot, ^desc.Descriptor, bool) {
    if s == nil {
        return nil, nil, false
    }
    snap := store.store_snapshot(a.docs, s.doc)
    if snap == nil {
        return nil, nil, false
    }
    return snap, store.store_descriptor(a.docs, s.doc), true
}

// A document's tab width, for the verbs whose goal column expands tabs (IME.md §4). The
// descriptor's and never a constant: tab_width is live plugin API.
doc_tab :: proc(a: ^App, id: store.Id) -> int {
    d := store.store_descriptor(a.docs, id)
    if d == nil {
        return 4
    }
    defer desc.release(d)
    return d.tab_width
}

@(private = "file")
active_tab :: proc(a: ^App) -> int {
    s := active(a)
    return s != nil ? doc_tab(a, s.doc) : 4
}

point_move :: proc(a: ^App, motion: txt.Motion, extend: bool) {
    s := active(a)
    doc := s != nil ? store.store_doc(a.docs, s.doc) : nil
    if doc == nil {
        return
    }
    // §7's export to the pipeline, and the whole of it: the runs of the original no cell stands
    // for. `txt` takes a slice and stays pure — it never learns what a fold is.
    txt.doc_move(doc, motion, extend, hidden = views_hidden(a, s.doc), tab = active_tab(a))
    point_sync(a)
    snap := store.store_snapshot(a.docs, s.doc)
    if snap == nil {
        return
    }
    defer pt.snapshot_release(snap)
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
    defer pt.snapshot_release(snap)
    defer desc.release(d)
    r := active_rect(a)
    t, dv := views_text(a, s.doc, &snap.text)
    fields := shown_fields(a, s.doc, t, dv, s.view.top, r.h)
    p, _, hit := view.locate(t, d, fields, s.view, r.x, r.y, r.w, r.h, cx, cy, dv)
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
    path, _ := bind_path(a)
    if b, ok := input.bind_lookup(a.binds[:], {input.mouse_code(m), mods}, path); ok {
        if cmd, named := line_command(b.line); named && command_places_point(cmd) {
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
    defer pt.snapshot_release(snap)
    defer desc.release(d)
    doc := store.store_doc(a.docs, s.doc)
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
    snap := store.store_snapshot(a.docs, s.doc)
    if snap == nil {
        return
    }
    defer pt.snapshot_release(snap)
    t, _ := views_text(a, s.doc, &snap.text) // `top` is a line of the DRAWN document
    view.scroll(&s.view, t, lines)
}

// --- hover (§8) ---

// A lone `:verb` line naming a kernel or plugin verb, as opposed to a line that does something
// with what is under point.
@(private = "file")
verb_line :: proc(a: ^App, line: string) -> bool {
    name := lone_verb(line) or_return
    _, kernel := command_named(name)
    _, registered := plug_cmd_named(a, name)
    return kernel || registered
}

// Would a click here run a command line rather than a verb. Either button chord, because a document whose single
// click only moves point may still answer the second one — which is what a listing you can also
// type into wants (the row navigates, the click lands a caret).
@(private = "file")
clickable :: proc(a: ^App, d: ^desc.Descriptor) -> bool {
    path, _ := section_path(a, kind_section(a, d.kind))
    for button in ([?]input.Mouse{.Click, .Double_Click}) {
        chord := input.Chord{input.mouse_code(button), {}}
        if bind, bound := input.bind_lookup(a.binds[:], chord, path); bound {
            if !verb_line(a, bind.line) {
                return true
            }
        }
    }
    return false
}

// A field is a link when its name is one a line can read as `$o_name`: what an owner publishes
// under one of those is something a key or a click can act on.
is_link :: proc(name: string) -> bool {
    _, ok := cl.var_index(name)
    return ok
}

// The one link that is LIVE: the field under the pointer, or the row the caret is on, which is
// what `enter` acts on. Its own token, so a page of offers says which one the next keystroke
// takes. Only where the caret is drawn — an unfocused panel has no next keystroke.
doc_link_over :: proc(a: ^App, p: ^Panel, fields: []desc.Field,
                      v: view.View, marked: bool,
                      allocator := context.temp_allocator) -> []view.Style {
    line, lo, hi := p.hover.line, p.hover.lo, p.hover.hi
    if !p.hover.on {
        if !marked {
            return nil
        }
        at := v.point.head
        under, ok := link_at(fields, at)
        if !ok {
            return nil
        }
        line, lo, hi = at.line, under.lo, under.hi
    }
    fg, bg := u32(token_intern(a, TOKEN_LINK_OVER)), u32(gfx.Token.Bg)
    out := make([dynamic]view.Style, 0, 1, allocator)
    append(&out, view.Style{line, lo, hi, fg, bg, {.Underline}})
    return out[:]
}

// The link a caret acts on, by the rule `$o_` names fill by (desc.field_under).
@(private = "file")
link_at :: proc(fields: []desc.Field, at: txt.Pos) -> (desc.Field, bool) {
    for name in cl.VARS {
        if f, named := desc.field_under(fields, at.line, at.col, name); named && f.lo < f.hi {
            return f, true
        }
    }
    return {}, false
}

// Ask the bind table whether a click here would do anything, and underline the field it would
// act on. Three consequences of "a click is a chord", and no surface writes a line of any of
// them. The panel is the POINTER'S and not the focused one's, because that is where the
// underline goes; leaving every panel puts it away.
hover_update :: proc(a: ^App, panel, cx, cy: int) {
    was := hover_on(a)
    hover_clear(a)
    defer if hover_on(a) != was && a.window != nil {
        _ = sdl.SetCursor(hover_on(a) ? a.hand : sdl.GetDefaultCursor())
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
    defer pt.snapshot_release(snap)
    defer desc.release(d)
    b := pn.body
    t, dv := views_text(a, s.doc, &snap.text)
    fields := shown_fields(a, s.doc, t, dv, s.view.top, b.h)
    p, field, hit := view.locate(t, d, fields, s.view, b.x, b.y, b.w, b.h, cx, cy, dv)
    if !hit || field == "" {
        return
    }
    if !clickable(a, d) {
        return
    }
    if f, linked := link_at(fields, p); linked && f.lo <= p.col && p.col < f.hi {
        pn.hover = {p.line, f.lo, f.hi, true}
    }
}

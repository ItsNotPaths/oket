package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
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
prefix_arm :: proc(a: ^App, chord: input.Chord, ctx: input.Bind_Ctx, kind: input.Kind) -> bool {
    if !input.bind_primes(a.binds[:], chord, ctx, kind) {
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
    return {code, prefix.mods, 0}
}

// The two keys a primer reserves, and then the outcomes below. Both reserved chords are answered
// here rather than in the resolve, because both are about the PRIMER and neither is a child.
@(private = "file")
prefix_take :: proc(a: ^App, chord: input.Chord) -> bool {
    p, _ := a.pending.(input.Pending_Prefix)
    esc, _ := input.key_code("ESC")
    // Escape is unmodified and would fall through to quit, so it cancels ahead of the rule
    // below. The help chord is the one other key the primer reserves.
    if chord == (input.Chord{esc, {}, 0}) {
        input.pending_set(&a.pending)
        return true
    }
    // Code and mods, and `held` deliberately left out: keeping `x` down through `m-x` into
    // `m-space` fills `held` with `x`, and an equality test against a zero one would miss the
    // chord the user actually typed.
    if h := prefix_help(p.chord); chord.code == h.code && chord.mods == h.mods {
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
    ctx, kind := bind_ctx(a)
    if b, extend, ok := input.bind_lookup(a.binds[:], chord, ctx, kind, prefix); ok {
        bind_dispatch(a, chord, b, extend)
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
        // A chord no row claims may still be a PRIMER, which is a row's prefix and never a row
        // of its own (§4.1). Asked after the lookup, so a chord that already runs something
        // keeps running it and the clash is what the home page reports. Never over a pending:
        // arming would close the command line or drop an armed pick.
        if a.pending == nil && prefix_arm(a, chord, ctx, kind) {
            return
        }
        // The miss rule (§8, §14): a context whose documents have a job of their own forwards,
        // and everything else stays quiet. A chord that IS bound and does nothing is the thing
        // that section exists to prevent; an unbound one is just an unbound one.
        if input.ctx_miss(ctx) == .Surface_Send {
            surface_send(a, chord)
        }
        return
    }
    bind_dispatch(a, chord, b, extend)
}

// A resolved row, run. Split from handle_chord so a child reached under a primer takes exactly
// the path its plain sibling takes (§4.2) — and so a row PRESSED in the menu takes it too, which
// is the whole of "the menu does what typing it does" (MENU.md §1).
bind_dispatch :: proc(a: ^App, chord: input.Chord, b: input.Bind, extend: bool) {
    if line, is_line := b.target.(input.Bind_Line); is_line {
        bind_line_fire(a, chord, line)
        return
    }
    if slot, registered := b.target.(input.Slot); registered {
        plug_command(a, slot, "")
        return
    }
    cmd, _ := input.bind_command(b) // the line and slot arms returned, so a Command is all that is left
    // A cycle only means anything straight after a paste, so every other verb puts the mark
    // down. That is what keeps ctrl+shift+v config rather than a mode.
    if cmd != .Paste && cmd != .Paste_Cycle {
        a.paste.live = false
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
    case .Copy:
        copy_doc(a)
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
    case .Menu_Open:
        menu_open(a)
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
        message_set(a, fmt.tprintf("%s is not built yet", input.COMMANDS[cmd].name))
    }
}

// One wheel notch. A config value once config.conf lands (§4).
WHEEL_LINES :: 3

// Which range a kill verb takes, in the shape motion_of already answers.
@(private = "file")
kill_of :: proc(cmd: input.Command) -> (txt.Kill, bool) {
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
    a.paste.live = false // typing is one of the "every other verb" the mark is put down for
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

// --- the clipboard ---

// The system clipboard is the copy path, both ways: what is copied here pastes into a browser,
// and a browser's copy pastes here. This is the GLFW half of txt's doc_copy/doc_cut/doc_paste.
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

// `a.clips[0]` is what oket last put on the clipboard. GLFW answers with nothing when there is
// no window, and on X11 when the selection has been dropped — in both cases our own copy is
// still the truthful answer to "what did I copy", so it is the fallback rather than a cache.
clip_get :: proc(a: ^App) -> string {
    text := glfw.GetClipboardString(a.window)
    return text != "" ? text : clip_head(a).text
}

clip_set :: proc(a: ^App, text: string, pieces: []string = nil) {
    clip_push(a, text, pieces)
    glfw.SetClipboardString(a.window, strings.clone_to_cstring(text, context.temp_allocator))
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

// The fields on the visible rows that something would ACT on, as style runs (§8). A link is a
// field some LINE names, and the lines are the ones already written down: the rows reachable in
// this document's own context, and the table `:home enter` runs behind one row (home.odin). So
// a link is drawn exactly where a key or a click would do something, and neither table is read
// twice for it.
//
// Per frame rather than published into the span store, because both halves move under it — the
// descriptor with every submit, the lines with every binds.conf re-read.
doc_links :: proc(a: ^App, d: ^desc.Descriptor, first, last: int,
                  allocator := context.temp_allocator) -> []view.Style {
    if d == nil {
        return nil // nothing resolved a descriptor, so there are no fields to be links
    }
    names := link_names(a, d, allocator)
    if len(names) == 0 {
        return nil
    }
    fg, bg := token_color(a, token_intern(a, TOKEN_LINK)), a.theme[.Bg]
    out := make([dynamic]view.Style, allocator)
    for at in first ..< last {
        for name in names {
            if lo, hi, named := desc.field_span(d, at, name); named && lo < hi {
                append(&out, view.Style{at, lo, hi, fg, bg, {.Underline}})
            }
        }
    }
    return out[:]
}

@(private = "file")
link_names :: proc(a: ^App, d: ^desc.Descriptor,
                   allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, allocator)
    for b in a.binds {
        if !input.bind_reachable(b, d.ctx, d.kind) {
            continue
        }
        if line, is_line := b.target.(input.Bind_Line); is_line {
            link_holes(&out, line.text)
        }
    }
    for v in HOME_VERBS {
        link_holes(&out, v.line) // a name no document carries costs a lookup that misses
    }
    return out[:]
}

@(private = "file")
link_holes :: proc(out: ^[dynamic]string, template: string) {
    rest := template
    for {
        _, name, tail, found := hole_next(rest)
        if !found {
            return
        }
        if !slice.contains(out[:], name) {
            append(out, name)
        }
        rest = tail
    }
}

// The one link that is LIVE: the field under the pointer, or the row the caret is on, which is
// what `enter` acts on. Its own token, so a page of offers says which one the next keystroke
// takes. Only where the caret is drawn — an unfocused panel has no next keystroke.
doc_link_over :: proc(a: ^App, p: ^Panel, d: ^desc.Descriptor, v: view.View, marked: bool,
                      allocator := context.temp_allocator) -> []view.Style {
    line, lo, hi := p.hover.line, p.hover.lo, p.hover.hi
    if !p.hover.on {
        if !marked {
            return nil
        }
        at := v.point.head.line
        first, ok := link_at(a, d, at)
        if !ok {
            return nil
        }
        line, lo, hi = at, first.lo, first.hi
    }
    fg, bg := token_color(a, token_intern(a, TOKEN_LINK_OVER)), a.theme[.Bg]
    out := make([dynamic]view.Style, 0, 1, allocator)
    append(&out, view.Style{line, lo, hi, fg, bg, {.Underline}})
    return out[:]
}

// The link on a row, if it carries one. A row carrying more than one is a row `:home enter`
// would take the FIRST of, so this answers the same way it does.
@(private = "file")
link_at :: proc(a: ^App, d: ^desc.Descriptor, line: int) -> (desc.Field, bool) {
    if d == nil {
        return {}, false
    }
    for name in link_names(a, d) {
        if f, named := desc.field_of(d, line, name); named && f.lo < f.hi {
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

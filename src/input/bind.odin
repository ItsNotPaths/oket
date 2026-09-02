package input

import "core:fmt"

// The one place a chord is written down, keyed on physical codes. Contexts are declared now
// (the ring and editables arrive in later steps) but only Global has keys to claim yet.

Bind_Ctx :: enum u8 {
    Global,
    Text,
    Surface,
    Terminal,
}

Bind_Ctxs :: bit_set[Bind_Ctx;u8]

Command :: enum u8 {
    None,
    Quit,
    Describe_Key,
    Nav_Up,
    Nav_Down,
    Nav_Left,
    Nav_Right,
    Word_Left,
    Word_Right,
    Line_Home,
    Line_End,
    Doc_Start,
    Doc_End,
    Delete_Back,
    Delete_Forward,
    Delete_Word_Back,
    Delete_Word_Forward,
    Newline,
    Tab,
    Select_All,
    Cut,
    Copy,
    Paste,
    Paste_Cycle,
    Kill_Line,
    Kill_Whole_Line,
    Kill_To_Line_Start,
    Search_Next,
    Search_Prev,
    Save,
    Undo,
    Redo,
    Reload,
    Ring_Goto,
    Ring_Alt,
    Ring_Alt_Lane,
    Ring_Close,
    Ring_System,
    Jump_Back,
    Jump_Forward,
    CL_Open,
    CL_Sigil,
    Surface_Send,
    Term_Copy,
    Term_Paste,
    Term_Scroll_Up,
    Term_Scroll_Down,
    Term_Sel_Up,
    Term_Sel_Down,
    Font_Bigger,
    Font_Smaller,
    Font_Reset,
}

// The miss rule is data (§6): the command a context falls through to for a chord the table
// does not claim. A surface with its own key job takes the key, so copy-versus-kill is a bind
// and not a mode; everywhere else a miss is a no-op.
ctx_miss :: proc(ctx: Bind_Ctx) -> Command {
    #partial switch ctx {
    case .Terminal, .Surface:
        return .Surface_Send
    }
    return .None
}

// A registry slot, opaque here: `input` sits below the registry and never reads it.
Slot :: distinct u32

// A surface kind, opaque for the same reason. 0 is every kind, which is what a bind written
// against the plain `surface` context means.
Kind :: distinct u32

// A bind names a kernel verb, a registered one, or a command LINE (§6).
//
// The line arm is what keeps a plugin a value provider rather than a verb factory: the text is
// what you would otherwise have typed, with `<name>` holes the focused surface fills in, and
// `stage` decides whether it runs or lands in the command line for aiming (§5). One config line
// is then the whole policy, so `exec rm <path>` needs nothing at all from the plugin that drew
// the row it acts on.
Bind_Line :: struct {
    text:  string, // owned; `<name>` marks a hole
    stage: bool,
}

Bind_Target :: union #no_nil {
    Command,
    Slot,
    Bind_Line,
}

// Where a bind came from, so describe answers who bound it and where (§6). There is no
// plugin arm: a plugin's request becomes a file row, so the file is always the origin.
Origin_Src :: enum u8 {
    Kernel,
    Config,
}

Origin :: struct {
    src:  Origin_Src,
    name: string, // owned; the plugin's name or the file's, empty for a kernel default
    line: int, // the file line, 0 when it came from neither
}

Command_Info :: struct {
    name: string,
    doc:  string,
    ctx:  Bind_Ctxs,
}

// An enumerated array, so Odin refuses a literal with a member left out. The doc string is
// what describe answers with; a command without one cannot exist.
@(rodata)
COMMANDS := [Command]Command_Info {
    .None                = {"none", "the unbind value; no chord resolves to it", {}},
    .Quit                = {"quit", "close the window", {.Global}},
    .Describe_Key        = {"describe.key", "wait for one chord and say what it does", {.Global}},
    .Nav_Up              = {"nav.up", "move the caret up a line", {.Text}},
    .Nav_Down            = {"nav.down", "move the caret down a line", {.Text}},
    .Nav_Left            = {"nav.left", "move the caret left a rune", {.Text}},
    .Nav_Right           = {"nav.right", "move the caret right a rune", {.Text}},
    .Word_Left           = {"edit.word_left", "move the caret left a word", {.Text}},
    .Word_Right          = {"edit.word_right", "move the caret right a word", {.Text}},
    .Line_Home           = {"edit.home", "to the indent, then column 0", {.Text}},
    .Line_End            = {"edit.end", "to the end of the line", {.Text}},
    .Doc_Start           = {"edit.doc_start", "to the start of the document", {.Text}},
    .Doc_End             = {"edit.doc_end", "to the end of the document", {.Text}},
    .Delete_Back         = {"edit.delete_back", "delete the selection or the rune to the left", {.Text}},
    .Delete_Forward      = {"edit.delete_forward", "delete the selection or the rune to the right", {.Text}},
    .Delete_Word_Back    = {"edit.delete_word_back", "delete the word to the left", {.Text}},
    .Delete_Word_Forward = {"edit.delete_word_forward", "delete the word to the right", {.Text}},
    .Newline             = {"edit.newline", "split the line at the caret", {.Text}},
    .Tab                 = {"edit.tab", "insert a tab", {.Text}},
    .Select_All          = {"edit.select_all", "one selection over the whole document", {.Text}},
    .Cut                 = {"edit.cut", "cut the selection, or the line, to the kill ring", {.Text, .Surface}},
    .Copy                = {"edit.copy", "copy the selection, or the line, to the kill ring", {.Text, .Surface}},
    .Paste               = {"edit.paste", "insert the newest kill-ring entry", {.Text, .Surface}},
    .Paste_Cycle         = {"edit.paste_cycle", "replace the last paste with the entry before it", {.Text, .Surface}},
    .Kill_Line           = {"edit.kill_line", "kill from the caret to the end of the line", {.Text, .Surface}},
    .Kill_Whole_Line     = {"edit.kill_whole_line", "kill the line the caret is on", {.Text, .Surface}},
    .Kill_To_Line_Start  = {"edit.kill_to_line_start", "kill from the caret back to the start of the line", {.Text, .Surface}},
    .Search_Next         = {"search.next", "the next match of the last search, wrapping", {.Text, .Surface}},
    .Search_Prev         = {"search.prev", "the match before it, wrapping the other way", {.Text, .Surface}},
    .Save                = {"edit.save", "write the buffer to its file", {.Text, .Surface}},
    .Undo                = {"edit.undo", "undo the last step", {.Text, .Surface}},
    .Redo                = {"edit.redo", "redo the last undone step", {.Text, .Surface}},
    .Reload              = {"file.reload", "drop unsaved edits and take the disk version", {.Text, .Surface}},
    .Ring_Goto           = {"ring.goto", "go to slot N", {.Global}},
    .Ring_Alt            = {"ring.alt", "toggle the two most recent surfaces, whatever ring they are in", {.Global}},
    .Ring_Alt_Lane       = {"ring.alt_lane", "the same toggle, kept inside the ring you are in", {.Global}},
    .Ring_Close          = {"ring.close", "close the focused slot; its number is never reused while others live", {.Global}},
    .Ring_System         = {"ring.system", "go to N#, the system session", {.Global}},
    .Jump_Back           = {"jump.back", "to the previous position in the jump ring, across surfaces", {.Global}},
    .Jump_Forward        = {"jump.forward", "back toward the position you jumped from", {.Global}},
    .CL_Open             = {"cl.open", "open the command line", {.Global}},
    .CL_Sigil            = {"cl.sigil", "open the command line with the builtin : typed", {.Global}},
    .Surface_Send        = {"surface.send", "send the key to the focused surface's own job", {.Terminal, .Surface}},
    .Term_Copy           = {"term.copy", "copy the selected lines to the clipboard", {.Terminal}},
    .Term_Paste          = {"term.paste", "paste the clipboard as bracketed input", {.Terminal}},
    .Term_Scroll_Up      = {"term.scroll_up", "scroll the view a page into history", {.Terminal}},
    .Term_Scroll_Down    = {"term.scroll_down", "scroll the view a page toward the bottom", {.Terminal}},
    .Term_Sel_Up         = {"term.sel_up", "move the copy cursor up a line", {.Terminal}},
    .Term_Sel_Down       = {"term.sel_down", "move the copy cursor down a line", {.Terminal}},
    .Font_Bigger         = {"font.bigger", "one step up in cell size; the grid holds fewer", {.Global}},
    .Font_Smaller        = {"font.smaller", "one step down in cell size; the grid holds more", {.Global}},
    .Font_Reset          = {"font.reset", "back to the size the system asked for", {.Global}},
}

// A verb by its registry name, which is the name the config, `:` and describe all use, so the
// three can never disagree about what a verb is called (§6).
command_named :: proc(name: string) -> (Command, bool) {
    for info, cmd in COMMANDS {
        if info.name == name && cmd != .None {
            return cmd, true
        }
    }
    return .None, false
}

Bind :: struct {
    chord:  Chord,
    target: Bind_Target,
    ctx:    Bind_Ctxs, // on the bind, not the verb: a plugin command has no COMMANDS row
    // Narrower than ctx: a row for one surface kind, which is how `enter` means one thing in a
    // browser and another in the editor while both are Surface. 0 claims every kind.
    kind:   Kind,
    origin: Origin,
    run:    Code, // extra codes past the first; alt+1..9 is one bind with run 8
}

// Binds own their line text and their origin's name, so the table is freed by proc and not by
// deleting the array.
binds_destroy :: proc(b: ^[dynamic]Bind) {
    for it in b {
        bind_free(it)
    }
    delete(b^)
    b^ = nil
}

bind_free :: proc(b: Bind) {
    if line, is_line := b.target.(Bind_Line); is_line {
        delete(line.text)
    }
    delete(b.origin.name)
}

// Tests and dispatch want the verb, not the union.
bind_command :: proc(b: Bind) -> (Command, bool) {
    c, ok := b.target.(Command)
    return c, ok
}

// How a plugin bind gets in: the caller resolved the name to a slot first (§6).
bind_add :: proc(b: ^[dynamic]Bind, chord: Chord, target: Bind_Target, ctx: Bind_Ctxs, run: Code = 0) {
    append(b, Bind{chord = chord, target = target, ctx = ctx, run = run})
}

// The kernel defaults, resolved through the name table so a typo dies at startup, not in a
// keystroke that goes nowhere.
binds_default :: proc(allocator := context.allocator) -> [dynamic]Bind {
    b := make([dynamic]Bind, allocator)
    bind_put(&b, "ESC", {}, .Quit)
    bind_put(&b, "FK01", {}, .Describe_Key)

    // Letter chords are POSITIONS (QWERTY letters name them below); a layout swap keeps them
    // under the same fingers.
    bind_put(&b, "UP", {}, .Nav_Up)
    bind_put(&b, "DOWN", {}, .Nav_Down)
    bind_put(&b, "LEFT", {}, .Nav_Left)
    bind_put(&b, "RGHT", {}, .Nav_Right)
    bind_put(&b, "LEFT", {.Ctrl}, .Word_Left)
    bind_put(&b, "RGHT", {.Ctrl}, .Word_Right)
    bind_put(&b, "HOME", {}, .Line_Home)
    bind_put(&b, "END", {}, .Line_End)
    bind_put(&b, "HOME", {.Ctrl}, .Doc_Start)
    bind_put(&b, "END", {.Ctrl}, .Doc_End)
    bind_put(&b, "BKSP", {}, .Delete_Back)
    bind_put(&b, "DELE", {}, .Delete_Forward)
    bind_put(&b, "BKSP", {.Ctrl}, .Delete_Word_Back)
    bind_put(&b, "DELE", {.Ctrl}, .Delete_Word_Forward)
    bind_put(&b, "RTRN", {}, .Newline)
    bind_put(&b, "KPEN", {}, .Newline)
    bind_put(&b, "TAB", {}, .Tab)
    // ctrl+a and ctrl+e are the most deployed pair there is: every readline prompt and every
    // Cocoa text field. Arrows already carry motion, so the only cost is select-all, which
    // stays a verb with no default chord (Emacs gives it none either).
    bind_put(&b, "AC01", {.Ctrl}, .Line_Home) // ctrl+a
    bind_put(&b, "AD03", {.Ctrl}, .Line_End) // ctrl+e
    bind_put(&b, "AC02", {.Ctrl}, .Save) // ctrl+s
    bind_put(&b, "AB01", {.Ctrl}, .Undo) // ctrl+z
    bind_put(&b, "AB01", {.Ctrl, .Shift}, .Redo) // a different verb, so Shift is written out
    bind_put(&b, "FK03", {}, .Search_Next)
    bind_put(&b, "FK03", {.Shift}, .Search_Prev)
    bind_put(&b, "FK05", {}, .Reload)

    // The modern spelling, not Emacs's C-w/M-w/C-y: C-w is the close-window reflex everywhere
    // else. The kill RING is Emacs's — ctrl+shift+v walks it, yank-pop under a guessable name.
    // All {.Text, .Surface} and never {.Global}: Terminal is not in the set, so bind_find misses
    // and the miss rule forwards, which is what keeps ctrl+c a SIGINT in a shell.
    bind_put(&b, "AB02", {.Ctrl}, .Cut) // ctrl+x
    bind_put(&b, "AB03", {.Ctrl}, .Copy) // ctrl+c
    bind_put(&b, "AB04", {.Ctrl}, .Paste) // ctrl+v
    bind_put(&b, "AB04", {.Ctrl, .Shift}, .Paste_Cycle)
    bind_put(&b, "AC08", {.Ctrl}, .Kill_Line) // ctrl+k
    bind_put(&b, "AC08", {.Ctrl, .Shift}, .Kill_Whole_Line)
    bind_put(&b, "AD07", {.Ctrl}, .Kill_To_Line_Start) // ctrl+u, readline's unix-line-discard

    bind_put(&b, "AE01", {.Alt}, .Ring_Goto) // alt+1..9, one bind with run 8
    bind_put(&b, "TLDE", {.Alt}, .Ring_Alt) // alt+` sits at the number row's door
    bind_put(&b, "TLDE", {.Alt, .Shift}, .Ring_Alt_Lane) // and Shift keeps it in one ring
    bind_put(&b, "AD01", {.Alt}, .Ring_Close) // alt+q
    bind_put(&b, "AE10", {.Alt}, .Ring_System) // alt+0: at the rotation's edge, not in it (§11)
    // Browser back and forward, because that is what a jump ring is and everybody already knows
    // the gesture. Alt keeps meaning "move between things", which is what the ring is (§5).
    bind_put(&b, "LEFT", {.Alt}, .Jump_Back)
    bind_put(&b, "RGHT", {.Alt}, .Jump_Forward)
    // The universal spelling, and it moves the TEXT rather than the grid: ctrl+= is bigger
    // glyphs, which is fewer cells.
    bind_put(&b, "AE12", {.Ctrl}, .Font_Bigger) // ctrl+=
    bind_put(&b, "AE11", {.Ctrl}, .Font_Smaller) // ctrl+-
    bind_put(&b, "AE10", {.Ctrl}, .Font_Reset) // ctrl+0
    bind_put(&b, "AB03", {.Alt}, .CL_Open) // alt+c
    bind_put(&b, "AC10", {.Alt}, .CL_Sigil) // alt+;

    // Surface claims: context-specific, so they shadow the global rows above (Esc must reach
    // vim inside the shell, never quit oket). Shift+Ctrl+Up extends via the Shift fallback.
    bind_put(&b, "ESC", {}, .Surface_Send)
    bind_put(&b, "AB03", {.Ctrl, .Shift}, .Term_Copy) // ctrl+shift+c
    bind_put(&b, "AB04", {.Ctrl, .Shift}, .Term_Paste) // ctrl+shift+v
    bind_put(&b, "PGUP", {.Shift}, .Term_Scroll_Up)
    bind_put(&b, "PGDN", {.Shift}, .Term_Scroll_Down)
    bind_put(&b, "UP", {.Ctrl}, .Term_Sel_Up)
    bind_put(&b, "DOWN", {.Ctrl}, .Term_Sel_Down)
    return b
}

@(private = "file")
bind_put :: proc(b: ^[dynamic]Bind, key: string, mods: Mods, cmd: Command) {
    code, ok := key_code(key)
    assert(ok, "a kernel default names a key that is not in the table")
    bind_add(b, {code, mods}, cmd, COMMANDS[cmd].ctx, cmd == .Ring_Goto ? 8 : 0)
}

// Narrowest row wins: one written for this surface kind, then one for the context, then a
// Global one (`esc = surface.send` shadows the global quit). First exact match inside a tier.
// A bind with a run answers for its whole key range; the caller reads the offset off
// b.chord.code.
bind_find :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0) -> (Bind, bool) {
    if kind != 0 {
        if b, ok := bind_scan(binds, chord, {ctx}, kind); ok {
            return b, true
        }
    }
    if ctx != .Global {
        if b, ok := bind_scan(binds, chord, {ctx}, 0); ok {
            return b, true
        }
    }
    return bind_scan(binds, chord, {.Global}, 0)
}

@(private = "file")
bind_scan :: proc(binds: []Bind, chord: Chord, want: Bind_Ctxs, kind: Kind) -> (Bind, bool) {
    for b in binds {
        if b.chord.mods == chord.mods &&
           chord.code >= b.chord.code &&
           chord.code <= b.chord.code + b.run &&
           b.kind == kind &&
           b.ctx & want != {} {
            return b, true
        }
    }
    return {}, false
}

// One tier, no fallthrough: is THIS ctx-and-kind already holding the chord. The clash check
// wants this and not bind_lookup, because a narrower row shadowing a wider one is the feature
// (§6) and a resolving lookup reports it as a collision.
bind_at :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0) -> (Bind, bool) {
    return bind_scan(binds, chord, {ctx}, kind)
}

// Shift is not written into most binds: a Shift-qualified chord matching nothing exactly
// retries without it and runs `extend`ing, so Shift+Down sweeps a selection. An exact Shift
// row (ctrl+shift+z) beats the fallback, which is how Shift names a DIFFERENT verb.
bind_lookup :: proc(
    binds: []Bind,
    chord: Chord,
    ctx: Bind_Ctx,
    kind: Kind = 0,
) -> (
    b: Bind,
    extend, ok: bool,
) {
    if b, ok = bind_find(binds, chord, ctx, kind); ok {
        return b, false, true
    }
    if .Shift in chord.mods {
        b, ok = bind_find(binds, {chord.code, chord.mods - {.Shift}}, ctx, kind)
        return b, ok, ok
    }
    return {}, false, false
}

// Total over chords: every code, named or not, bound or not, gets an answer (§6). The layout
// spelling first, the physical spelling always, then what it runs and who bound it.
// describe stays total over plugin verbs (§6), so the caller lends it a registry reader.
Slot_Namer :: struct {
    user: rawptr,
    fn:   proc(user: rawptr, slot: Slot) -> (name, doc: string),
}

// Not file-private: the bind file's clash note names what a chord runs already.
target_info :: proc(t: Bind_Target, namer: Slot_Namer) -> (name, doc: string) {
    switch v in t {
    case Command:
        return COMMANDS[v].name, COMMANDS[v].doc
    case Slot:
        if namer.fn != nil {
            return namer.fn(namer.user, v)
        }
        return "?", "a registered command this caller cannot name"
    case Bind_Line:
        return v.text, v.stage ? "staged in the command line for aiming" : "run as typed"
    }
    return "", ""
}

// `kernel default`, `binds.conf:14` — the half of describe that answers who bound this,
// which is the Emacs failure the whole facility exists to prevent (§6).
origin_label :: proc(o: Origin) -> string {
    switch o.src {
    case .Kernel:
        return "kernel default"
    case .Config:
        return o.line > 0 ? fmt.tprintf("%s:%d", o.name, o.line) : o.name
    }
    return "?"
}

describe_chord :: proc(
    binds: []Bind,
    chord: Chord,
    ctx: Bind_Ctx,
    layout: Layout_Name,
    namer: Slot_Namer = {},
    kind: Kind = 0,
    allocator := context.allocator,
) -> string {
    spelling := chord_format(chord, layout, context.temp_allocator)
    phys := chord_physical(chord, context.temp_allocator)
    if spelling == phys { // a nameless code has only the one spelling
        phys = ""
    } else {
        phys = fmt.tprintf(" (%s)", phys)
    }

    b, extend, bound := bind_lookup(binds, chord, ctx, kind)
    if !bound {
        if miss := ctx_miss(ctx); miss != .None {
            return fmt.aprintf(
                "%s%s is unbound, falls through to %s: %s",
                spelling, phys, COMMANDS[miss].name, COMMANDS[miss].doc,
                allocator = allocator,
            )
        }
        return fmt.aprintf("%s%s is unbound", spelling, phys, allocator = allocator)
    }
    name, doc := target_info(b.target, namer)
    claimed := .Global in b.ctx ? Bind_Ctx.Global : ctx
    verb := "runs"
    if line, is_line := b.target.(Bind_Line); is_line && line.stage {
        verb = "stages"
    }
    return fmt.aprintf(
        "%s%s %s %s: %s%s [%v, %s]",
        spelling,
        phys,
        verb,
        name,
        doc,
        extend ? ", extending the selection" : "",
        claimed,
        origin_label(b.origin),
        allocator = allocator,
    )
}

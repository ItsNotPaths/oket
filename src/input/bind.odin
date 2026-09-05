package input

import "core:fmt"
import "core:strings"

// The one place a chord is written down, keyed on physical codes. Contexts are declared now
// (the ring and editables arrive in later steps) but only Global has keys to claim yet.

Bind_Ctx :: enum u8 {
    Global,
    Text,
    Surface,
    Terminal,
    // The armed picker (PANELS.md §6). Entered when a `pick` row fires and left when its held
    // key comes up, so left and right choose a panel for exactly as long as the gesture lasts.
    Pick,
}

Bind_Ctxs :: bit_set[Bind_Ctx;u8]

// A context by its config spelling, the one name binds.conf, `:` and describe all use, so the
// three can never disagree about what a context is called (§6). Enumerated, like COMMANDS, so
// Odin refuses a literal with a member left out.
@(rodata)
CTX_NAMES := [Bind_Ctx]string {
    .Global   = "global",
    .Text     = "text",
    .Surface  = "surface",
    .Terminal = "terminal",
    .Pick     = "pick",
}

ctx_named :: proc(name: string) -> (Bind_Ctx, bool) {
    for n, ctx in CTX_NAMES {
        if n == name {
            return ctx, true
        }
    }
    return .Global, false
}

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
    Select_Expand,
    Cursor_Add,
    Cursor_Add_Below,
    Cursor_Add_Above,
    Cursor_Add_Next,
    Cursor_Add_All,
    Cursor_Split,
    Cursor_Collapse,
    View_Scroll_Up,
    View_Scroll_Down,
    View_Page_Up,
    View_Page_Down,
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
    Panel_Open,
    Panel_Close,
    Panel_Next,
    Panel_Prev,
    Panel_Move_Left,
    Panel_Move_Right,
    Pick_Left,
    Pick_Right,
    Pick_Cancel,
    Jump_Back,
    Jump_Forward,
    CL_Open,
    CL_Sigil,
    Menu_Open,
    Surface_Send,
    Term_Copy,
    Term_Paste,
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

// A verb that places its own point. The kernel moves point to the cell under the pointer before
// it dispatches a button chord (§8), and for these that move would take down the very carets the
// verb exists to add to — so the press skips it, and describe says `runs` instead of `moves
// point, then runs`.
command_places_point :: proc(c: Command) -> bool {
    return c == .Cursor_Add
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
// the mode decides whether it runs, lands in the command line for aiming (§5), or waits (§6).
// One config line is then the whole policy, so `exec rm <path>` needs nothing at all from the
// plugin that drew the row it acts on.
//
// `pick` is the third of them (PANELS.md §6): the line expands at the PRESS, so its holes fill
// from where point was, and it runs at the RELEASE of the chord's held key with `@` aimed at
// the panel that was steered to.
Bind_Mode :: enum u8 {
    Exec,
    Stage,
    Pick,
}

Bind_Line :: struct {
    text: string, // owned; `<name>` marks a hole
    mode: Bind_Mode,
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
    .Quit                = {"file.quit", "close the window", {.Global}},
    .Describe_Key        = {"describe.key", "wait for one chord and say what it does", {.Global}},
    .Nav_Up              = {"nav.up", "move the caret up a line", {.Text, .Surface}},
    .Nav_Down            = {"nav.down", "move the caret down a line", {.Text, .Surface}},
    .Nav_Left            = {"nav.left", "move the caret left a rune", {.Text, .Surface}},
    .Nav_Right           = {"nav.right", "move the caret right a rune", {.Text, .Surface}},
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
    .Select_Expand       = {"select.expand", "select what point sits in, at the document's own granularity", {.Text, .Surface}},
    .Cursor_Add          = {"cursor.add", "a caret under the pointer, keeping the ones already up", {.Text, .Surface}},
    .Cursor_Add_Below    = {"cursor.add_below", "a caret on the line under the lowest one", {.Text, .Surface}},
    .Cursor_Add_Above    = {"cursor.add_above", "a caret on the line over the highest one", {.Text, .Surface}},
    .Cursor_Add_Next     = {"cursor.add_next_match", "select the word under point, then a caret over each next match of it", {.Text, .Surface}},
    .Cursor_Add_All      = {"cursor.add_all_matches", "the same seed, then a caret over every match at once", {.Text, .Surface}},
    .Cursor_Split        = {"cursor.split_lines", "one caret per line of each selection", {.Text, .Surface}},
    .Cursor_Collapse     = {"cursor.collapse", "put the trail down; only the primary caret is left", {.Text, .Surface}},
    .View_Scroll_Up      = {"view.scroll_up", "scroll the view toward the start; point stays put", {.Global}},
    .View_Scroll_Down    = {"view.scroll_down", "scroll the view toward the end; point stays put", {.Global}},
    .View_Page_Up        = {"view.page_up", "scroll the view back one screenful; point stays put", {.Global}},
    .View_Page_Down      = {"view.page_down", "scroll the view on one screenful; point stays put", {.Global}},
    .Cut                 = {"edit.cut", "cut the selection, or the line, to the clipboard", {.Text, .Surface}},
    .Copy                = {"edit.copy", "copy the selection, or the line, to the clipboard", {.Text, .Surface}},
    .Paste               = {"edit.paste", "insert what the clipboard holds", {.Text, .Surface}},
    .Paste_Cycle         = {"edit.paste_cycle", "replace the last paste with the entry before it", {.Text, .Surface}},
    .Kill_Line           = {"edit.kill_line", "kill from the caret to the end of the line", {.Text, .Surface}},
    .Kill_Whole_Line     = {"edit.kill_whole_line", "kill the line the caret is on", {.Text, .Surface}},
    .Kill_To_Line_Start  = {"edit.kill_to_line_start", "kill from the caret back to the start of the line", {.Text, .Surface}},
    .Search_Next         = {"search.next", "the next match of the last search, wrapping", {.Text, .Surface}},
    .Search_Prev         = {"search.prev", "the match before it, wrapping the other way", {.Text, .Surface}},
    .Save                = {"file.dump", "write the focused document beside the binary, whatever opened it", {.Text, .Surface}},
    .Undo                = {"edit.undo", "undo the last step", {.Text, .Surface}},
    .Redo                = {"edit.redo", "redo the last undone step", {.Text, .Surface}},
    .Reload              = {"file.reload", "drop unsaved edits and take the disk version", {.Text, .Surface}},
    .Ring_Goto           = {"ring.goto", "go to slot N", {.Global}},
    .Ring_Alt            = {"ring.alt", "toggle the two most recent surfaces, whatever ring they are in", {.Global}},
    .Ring_Alt_Lane       = {"ring.alt_lane", "the same toggle, kept inside the ring you are in", {.Global}},
    .Ring_Close          = {"ring.close", "close the focused slot; its number is never reused while others live", {.Global}},
    .Ring_System         = {"ring.system", "go to N#, the system session", {.Global}},
    .Panel_Open          = {"panel.open", "a panel to the right of this one, standing on nothing", {.Global}},
    .Panel_Close         = {"panel.close", "close the focused panel; what was in it stays in the ring", {.Global}},
    .Panel_Next          = {"panel.next", "focus the panel to the right", {.Global}},
    .Panel_Prev          = {"panel.prev", "focus the panel to the left", {.Global}},
    .Panel_Move_Left     = {"panel.move_left", "swap this panel with the one to its left", {.Global}},
    .Panel_Move_Right    = {"panel.move_right", "swap this panel with the one to its right", {.Global}},
    .Pick_Left           = {"pick.left", "steer the armed picker one panel left", {.Pick}},
    .Pick_Right          = {"pick.right", "steer the armed picker one panel right", {.Pick}},
    .Pick_Cancel         = {"pick.cancel", "drop the armed picker; nothing is opened", {.Pick}},
    .Jump_Back           = {"jump.back", "to the previous position in the jump ring, across surfaces", {.Global}},
    .Jump_Forward        = {"jump.forward", "back toward the position you jumped from", {.Global}},
    .CL_Open             = {"cl.open", "open the command line", {.Global}},
    .CL_Sigil            = {"cl.sigil", "open the command line with the builtin : typed", {.Global}},
    .Menu_Open           = {"menu.open", "open the menubar on its first menu", {.Global}},
    .Surface_Send        = {"surface.send", "send the key to the focused surface's own job", {.Terminal, .Surface}},
    .Term_Copy           = {"term.copy", "copy the selection, or the line point is on, to the system clipboard", {.Terminal}},
    .Term_Paste          = {"term.paste", "paste the clipboard as bracketed input", {.Terminal}},
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
    // `quit` is an accepted spelling of `file.quit` (MENU.md §3): every name is `group.verb`,
    // which is what a menu groups by, and a binds.conf that says `quit` still works.
    if name == "quit" {
        return .Quit, true
    }
    return .None, false
}

Bind :: struct {
    chord:  Chord,
    // The primer this row hides behind, zero for a row that answers on its own. A child is
    // invisible to the scan until its primer is pending, which is a FILTER and not a fallback:
    // nothing retries a miss with the prefix dropped.
    prefix: Chord,
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
bind_add :: proc(b: ^[dynamic]Bind, chord: Chord, target: Bind_Target, ctx: Bind_Ctxs,
                 run: Code = 0, kind := Kind(0), prefix := Chord{}) {
    append(b, Bind{chord = chord, prefix = prefix, target = target, ctx = ctx, run = run,
                   kind = kind})
}

// The kernel defaults, resolved through the name table so a typo dies at startup, not in a
// keystroke that goes nowhere.
binds_default :: proc(allocator := context.allocator) -> [dynamic]Bind {
    b := make([dynamic]Bind, allocator)
    bind_put(&b, "ESC", {}, .Quit)
    bind_put(&b, "FK01", {}, .Describe_Key)

    // Bare arrows move point in a SURFACE as well as in text: a listing's up and down is the
    // same point move, and nothing else claims an unmodified arrow there. Ctrl and Alt arrows
    // stay narrower, which is what leaves the terminal its own.
    //
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
    // The placement verbs (VIEWS.md §4). A caret is PLACED, not walked to, which is why there is
    // no prefix key and no armed mode here: each row says where the next caret goes, and the
    // arrows above already move the whole set. `cursor.split_lines` keeps no default chord and
    // `cursor.collapse` needs none — Escape answers it ahead of every row that claims the key,
    // for exactly as long as a trail is up.
    bind_put(&b, "DOWN", {.Ctrl, .Alt}, .Cursor_Add_Below)
    bind_put(&b, "UP", {.Ctrl, .Alt}, .Cursor_Add_Above)
    bind_put(&b, "AC03", {.Alt}, .Cursor_Add_Next) // alt+d
    bind_put(&b, "AC03", {.Alt, .Shift}, .Cursor_Add_All)
    // The mouse row costs nothing, because a button is already a chord (§8).
    bind_put(&b, "click", {.Alt}, .Cursor_Add)

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
    // The strip (PANELS.md §3, §5). Alt keeps meaning "move between things": the numbers walk
    // the ring, and the side arrows walk the panels. `jump.back` and `jump.forward` keep no
    // default chord until there is a jump ring to walk.
    bind_put(&b, "LEFT", {.Alt}, .Panel_Prev)
    bind_put(&b, "RGHT", {.Alt}, .Panel_Next)
    // Shift on the walk MOVES what you are looking at, which is the pairing every strip and
    // tab bar already uses. An exact Shift row, so the Shift fallback cannot reach `panel.prev`.
    bind_put(&b, "LEFT", {.Alt, .Shift}, .Panel_Move_Left)
    bind_put(&b, "RGHT", {.Alt, .Shift}, .Panel_Move_Right)
    bind_put(&b, "AD10", {.Alt}, .Panel_Open) // alt+p
    bind_put(&b, "AD10", {.Alt, .Shift}, .Panel_Close) // the panel, never the document in it
    // alt+w, for width. A LINE, because the sizing model is the row and not the kernel: rebind
    // the list and the same key is a toggle, a three-way or a set.
    bind_line(&b, "AD02", {.Alt}, ":width 30 50 100")
    // The universal spelling, and it moves the TEXT rather than the grid: ctrl+= is bigger
    // glyphs, which is fewer cells.
    bind_put(&b, "AE12", {.Ctrl}, .Font_Bigger) // ctrl+=
    bind_put(&b, "AE11", {.Ctrl}, .Font_Smaller) // ctrl+-
    bind_put(&b, "AE10", {.Ctrl}, .Font_Reset) // ctrl+0
    bind_put(&b, "AB03", {.Alt}, .CL_Open) // alt+c
    bind_put(&b, "AC10", {.Alt}, .CL_Sigil) // alt+;
    // alt+space; under a primer the same key carries THAT primer's modifier (MENU.md §5).
    bind_put(&b, PREFIX_HELP, {.Alt}, .Menu_Open)

    // Switching lanes is its own key, not a walk through the numbers (§5). These are LINES, so
    // the kind is named in a command line the user can read and rebind, and never in a case in
    // the dispatch — which is the whole reason `:ring` exists as a builtin.
    bind_line(&b, "AD03", {.Alt}, ":ring edit") // alt+e
    bind_line(&b, "AC04", {.Alt}, ":ring files") // alt+f
    bind_line(&b, "AD05", {.Alt}, ":ring term") // alt+t
    // alt+. — the lane switch for every OTHER kind, which is a plugin's and so has no letter of
    // its own here. Staged rather than run: the line is `:ring ` with the name left to type, and
    // a bare `:ring` lists the lanes for the times you have forgotten what one is called.
    bind_line(&b, "AB09", {.Alt}, ":ring ", .Stage)
    // A listing's rows are paths, and `enter` is what opens one. Written at the SURFACE tier
    // rather than for one kind: a surface whose lines carry no `path` reports that it cannot
    // fill the hole, which is data rather than a refusal decided per call (§8).
    bind_line(&b, "RTRN", {}, ":open <path>", ctx = {.Surface})
    // The picker (PANELS.md §6): hold tab, press enter on a link, steer, let tab go. `tab` and
    // `tab+enter` are DIFFERENT chords, so this shadows nothing — an editor keeps its indent.
    // `@` on its own is the panel steered to, which is the one address only a gesture can name.
    bind_line(&b, "RTRN", {}, ":open <path> @", .Pick, {.Surface}, held = "TAB")
    // The same open, one panel over, with no gesture at all. §6: the direction preference is a
    // ROW and not a config key, because a row is greppable, rebindable and describable.
    bind_line(&b, "RTRN", {.Ctrl}, ":open <path> @-1", ctx = {.Surface})
    // The same chord again, while armed: there is nowhere to throw this yet, so make somewhere.
    // A row, not a second meaning grown inside the picker — `[surface] tab+enter` is out of
    // reach while the `[pick]` context is on, so the two cannot be the same row by accident.
    bind_line(&b, "RTRN", {}, ":np", ctx = {.Pick}, held = "TAB")
    // While the picker is armed the side arrows choose a panel rather than move a caret. Rows,
    // because the context is entered at ARM time and shadows only what should be shadowed.
    bind_put(&b, "LEFT", {}, .Pick_Left)
    bind_put(&b, "RGHT", {}, .Pick_Right)
    bind_put(&b, "ESC", {}, .Pick_Cancel)

    // The mouse, as ordinary rows (§8). A button chord has none: the kernel moves point before
    // it dispatches one, so `click` with nothing bound already does the thing a click does, and
    // a row is what a surface adds to make it do more.
    bind_put(&b, "double-click", {}, .Select_Expand)
    bind_put(&b, "wheel-up", {}, .View_Scroll_Up)
    bind_put(&b, "wheel-down", {}, .View_Scroll_Down)

    // Surface claims: context-specific, so they shadow the global rows above (Esc must reach
    // vim inside the shell, never quit oket). Shift+Ctrl+Up extends via the Shift fallback.
    bind_put(&b, "ESC", {}, .Surface_Send)
    bind_put(&b, "AB03", {.Ctrl, .Shift}, .Term_Copy) // ctrl+shift+c
    bind_put(&b, "AB04", {.Ctrl, .Shift}, .Term_Paste) // ctrl+shift+v
    // Scrolling a session is the KERNEL's viewport over its document (§11), so these are the
    // same two verbs every other document has and there is no terminal scroll code to bind to.
    bind_put(&b, "PGUP", {.Shift}, .View_Page_Up)
    bind_put(&b, "PGDN", {.Shift}, .View_Page_Down)
    return b
}

// `text` is the line WITHOUT its `exec`, `stage` or `pick` word: those three spell the choice in
// a config row, and here it is the `mode` argument. `held` is the key a gesture holds, named the
// way a row names one. Not file-private: the kernel writes the rows that name a KIND, because a
// kind id is its own (kinds.odin) and this package holds one as identity it never reads.
bind_line :: proc(b: ^[dynamic]Bind, key: string, mods: Mods, text: string,
                  mode := Bind_Mode.Exec, ctx := Bind_Ctxs{.Global}, kind := Kind(0),
                  held := "") {
    code, ok := key_code(key)
    assert(ok, "a kernel default names a key that is not in the table")
    down, held_ok := key_code(held)
    assert(held == "" || held_ok, "a kernel default holds a key that is not in the table")
    bind_add(b, {code, mods, down}, Bind_Line{strings.clone(text), mode}, ctx, kind = kind)
}

@(private = "file")
bind_put :: proc(b: ^[dynamic]Bind, key: string, mods: Mods, cmd: Command) {
    code, ok := key_code(key)
    assert(ok, "a kernel default names a key that is not in the table")
    bind_add(b, {code, mods, 0}, cmd, COMMANDS[cmd].ctx, cmd == .Ring_Goto ? 8 : 0)
}

// A chord that is BOTH a primer and a row of its own. There is no priority between them: the
// scan answers with whichever row it reaches first, so one of the two can never fire. Reported
// rather than resolved — picking a winner here would be a precedence stack, and that is what
// §6 deleted.
Collision :: struct {
    chord: string, // the primer's spelling
    runs:  string, // the verb the plain row on that chord runs
    kids:  int,    // how many rows hide behind it
}

// Every such chord in the table, spelled. Derived on demand and never stored: a row the file
// grew since is in the answer at the next read.
bind_collisions :: proc(binds: []Bind, layout: Layout_Name, names: Names = {},
                        allocator := context.allocator) -> []Collision {
    out := make([dynamic]Collision, allocator)
    for b in binds {
        if b.prefix == (Chord{}) {
            continue
        }
        ctx := bind_one_ctx(b)
        // bind_lookup, not bind_find: the Shift retry reaches a plain row too, and this report
        // must ask exactly the question handle_chord asks.
        plain, _, taken := bind_lookup(binds, b.prefix, ctx, b.kind)
        if !taken {
            continue
        }
        spelling := chord_format(b.prefix, layout, allocator)
        if at, seen := collision_at(out[:], spelling); seen {
            out[at].kids += 1
            delete(spelling, allocator)
            continue
        }
        runs, _ := target_info(plain.target, names)
        append(&out, Collision{spelling, runs, 1})
    }
    return out[:]
}

collisions_destroy :: proc(c: []Collision, allocator := context.allocator) {
    for it in c {
        delete(it.chord, allocator)
    }
    delete(c, allocator)
}

@(private = "file")
collision_at :: proc(c: []Collision, chord: string) -> (int, bool) {
    for it, i in c {
        if it.chord == chord {
            return i, true
        }
    }
    return 0, false
}

// The context a row answers in, for the callers that need one and not a set. A row carries one
// in practice: the file writes a section, and a default names its verb's.
@(private = "file")
bind_one_ctx :: proc(b: Bind) -> Bind_Ctx {
    for ctx in Bind_Ctx {
        if ctx in b.ctx {
            return ctx
        }
    }
    return .Global
}

// The key that opens the menubar on a primer's own popout (MENU.md §5). Compared as a CHORD
// carrying the primer's modifier — `m-x` reserves `m-space`, `c-f` reserves `c-space` — so
// every chord a primer reserves is modified, exactly like every child it can reach, and an
// unmodified key under a primer always types.
//
// Space, because the one key that must work under EVERY primer cannot be a letter a plugin
// wants for a mnemonic, and because it is the same position on every layout.
PREFIX_HELP :: "SPCE"

// A primer is declared by its CHILDREN and by nothing else: no `ctrl+b = prefix` row to keep in
// step, and deleting the last child is what ends the primer. So arming asks the table whether
// any row hides behind this chord, in a context the keys can currently reach.
bind_primes :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0) -> bool {
    for b in binds {
        if b.prefix == chord && bind_reachable(b, ctx, kind) {
            return true
        }
    }
    return false
}

// The tiers bind_find would walk, as a predicate: this row's own kind, its context, or Global.
// Package-wide, because a reader asking what a DOCUMENT can do walks the table with it rather
// than writing the tiers down a second time (the kernel's link renderer).
bind_reachable :: proc(b: Bind, ctx: Bind_Ctx, kind: Kind) -> bool {
    if b.kind != 0 {
        return b.kind == kind && ctx in b.ctx
    }
    return ctx in b.ctx || .Global in b.ctx
}

// The children of a primer, spelled `chord verb` and joined, for the label the bar shows. Capped
// by the caller's budget rather than here, because what fits is the bar's question.
bind_children :: proc(binds: []Bind, prefix: Chord, ctx: Bind_Ctx, layout: Layout_Name,
                      names: Names = {}, kind: Kind = 0,
                      allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for it in binds {
        if it.prefix != prefix || !bind_reachable(it, ctx, kind) {
            continue
        }
        if strings.builder_len(b) > 0 {
            strings.write_string(&b, "  ")
        }
        name, _ := target_info(it.target, names)
        fmt.sbprintf(&b, "%s %s", chord_format(it.chord, layout, context.temp_allocator), name)
    }
    return strings.to_string(b)
}

// Narrowest row wins: one written for this surface kind, then one for the context, then a
// Global one (`esc = surface.send` shadows the global quit). First exact match inside a tier.
// A bind with a run answers for its whole key range; the caller reads the offset off
// b.chord.code.
bind_find :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0,
                  prefix := Chord{}) -> (Bind, bool) {
    if kind != 0 {
        if b, ok := bind_scan(binds, chord, {ctx}, kind, prefix); ok {
            return b, true
        }
    }
    if ctx != .Global {
        if b, ok := bind_scan(binds, chord, {ctx}, 0, prefix); ok {
            return b, true
        }
    }
    return bind_scan(binds, chord, {.Global}, 0, prefix)
}

@(private = "file")
bind_scan :: proc(binds: []Bind, chord: Chord, want: Bind_Ctxs, kind: Kind,
                  prefix := Chord{}) -> (Bind, bool) {
    for b in binds {
        if b.prefix == prefix &&
           b.chord.mods == chord.mods &&
           b.chord.held == chord.held &&
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
bind_at :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0,
                prefix := Chord{}) -> (Bind, bool) {
    return bind_scan(binds, chord, {ctx}, kind, prefix)
}

// Shift is not written into most binds: a Shift-qualified chord matching nothing exactly
// retries without it and runs `extend`ing, so Shift+Down sweeps a selection. An exact Shift
// row (ctrl+shift+z) beats the fallback, which is how Shift names a DIFFERENT verb.
bind_lookup :: proc(
    binds: []Bind,
    chord: Chord,
    ctx: Bind_Ctx,
    kind: Kind = 0,
    prefix := Chord{},
) -> (
    b: Bind,
    extend, ok: bool,
) {
    if b, ok = bind_find(binds, chord, ctx, kind, prefix); ok {
        return b, false, true
    }
    // The Shift retry stays UNDER the same primer: a child is reached by its own chord or not
    // at all, and dropping the prefix here would be the fallback tier the filter exists to deny.
    if .Shift in chord.mods {
        b, ok = bind_find(binds, {chord.code, chord.mods - {.Shift}, chord.held}, ctx, kind,
                          prefix)
        return b, ok, ok
    }
    return {}, false, false
}

// The registry, lent by the caller. `input` holds a Slot and a Kind as IDENTITY and never the
// table that names either, so describe borrows both readers rather than reaching for one. A
// zero value names nothing, and every reader below stays total without it (§6).
Names :: struct {
    user: rawptr,
    slot: proc(user: rawptr, slot: Slot) -> (name, doc: string),
    kind: proc(user: rawptr, kind: Kind) -> string,
}

// Not file-private: the bind file's clash note names what a chord runs already.
target_info :: proc(t: Bind_Target, names: Names) -> (name, doc: string) {
    switch v in t {
    case Command:
        return COMMANDS[v].name, COMMANDS[v].doc
    case Slot:
        if names.slot != nil {
            return names.slot(names.user, v)
        }
        return "?", "a registered command this caller cannot name"
    case Bind_Line:
        switch v.mode {
        case .Exec:
            return v.text, "run as typed"
        case .Stage:
            return v.text, "staged in the command line for aiming"
        case .Pick:
            return v.text, "expanded now, run at the release on the panel you steer to"
        }
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

// Total over chords: every code, named or not, bound or not, gets an answer (§6). The layout
// spelling first, the physical spelling always, then what it runs and who bound it.
describe_chord :: proc(
    binds: []Bind,
    chord: Chord,
    ctx: Bind_Ctx,
    layout: Layout_Name,
    names: Names = {},
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

    // A button chord moves point whether or not a row claims it, so an unbound one is still
    // not a no-op and describe must not call it unbound (§8).
    moves_point := false
    if m, is_mouse := mouse_of(chord.code); is_mouse {
        moves_point = mouse_moves_point(m)
    }

    b, extend, bound := bind_lookup(binds, chord, ctx, kind)
    if !bound {
        if moves_point {
            return fmt.aprintf(
                "%s moves point; nothing further is bound",
                spelling,
                allocator = allocator,
            )
        }
        // A primer is a row's PREFIX and never a row, so the lookup above misses it and
        // describe would call the chord unbound. It reads its children out instead.
        if bind_primes(binds, chord, ctx, kind) {
            kids := bind_children(binds, chord, ctx, layout, names, kind, context.temp_allocator)
            return fmt.aprintf("%s%s arms a primer: %s", spelling, phys, kids,
                               allocator = allocator)
        }
        if miss := ctx_miss(ctx); miss != .None {
            return fmt.aprintf(
                "%s%s is unbound, falls through to %s: %s",
                spelling, phys, COMMANDS[miss].name, COMMANDS[miss].doc,
                allocator = allocator,
            )
        }
        return fmt.aprintf("%s%s is unbound", spelling, phys, allocator = allocator)
    }
    if cmd, is_cmd := b.target.(Command); is_cmd && command_places_point(cmd) {
        moves_point = false
    }
    name, doc := target_info(b.target, names)
    // The tier the row actually won on. A kind row is narrower than its context, and saying
    // `surface` for one would be describe lying about which of two rows answered.
    claimed := CTX_NAMES[.Global in b.ctx ? Bind_Ctx.Global : ctx]
    if b.kind != 0 && names.kind != nil {
        if n := names.kind(names.user, b.kind); n != "" {
            claimed = n
        }
    }
    verb := "runs"
    if line, is_line := b.target.(Bind_Line); is_line {
        #partial switch line.mode {
        case .Stage:
            verb = "stages"
        case .Pick:
            verb = "arms"
        }
    }
    if moves_point {
        verb = fmt.tprintf("moves point, then %s", verb)
    }
    return fmt.aprintf(
        "%s%s %s %s: %s%s [%s, %s]",
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

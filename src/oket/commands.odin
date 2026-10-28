package main

import "core:strings"

// The kernel's own verbs. A bind holds a command line; a lone `:verb` line names one of these, and
// `input` never sees the enum.
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
    Para_Up,
    Para_Down,
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
    Ring_Goto,
    Ring_Alt,
    Ring_Alt_Lane,
    Ring_Close,
    Ring_Zero,
    Panel_Open,
    Panel_Close,
    Panel_Next,
    Panel_Prev,
    Panel_Move_Left,
    Panel_Move_Right,
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

Command_Info :: struct {
    name: string,
    doc:  string,
}

// An enumerated array, so Odin refuses a literal with a member left out. The doc string is
// what describe answers with; a command without one cannot exist.
@(rodata)
COMMANDS := [Command]Command_Info {
    .None                = {"none", "the unbind value; no chord resolves to it"},
    .Quit                = {"file.quit", "close the window"},
    .Describe_Key        = {"describe.key", "wait for one chord and say what it does"},
    .Nav_Up              = {"nav.up", "move the caret up a line"},
    .Nav_Down            = {"nav.down", "move the caret down a line"},
    .Nav_Left            = {"nav.left", "move the caret left a rune"},
    .Nav_Right           = {"nav.right", "move the caret right a rune"},
    .Word_Left           = {"edit.word_left", "move the caret left a word"},
    .Word_Right          = {"edit.word_right", "move the caret right a word"},
    .Line_Home           = {"edit.home", "to the indent, then column 0"},
    .Line_End            = {"edit.end", "to the end of the line"},
    .Doc_Start           = {"edit.doc_start", "to the start of the document"},
    .Doc_End             = {"edit.doc_end", "to the end of the document"},
    .Para_Up             = {"edit.para_up", "to the blank line before the paragraph"},
    .Para_Down           = {"edit.para_down", "to the blank line after the paragraph"},
    .Delete_Back         = {"edit.delete_back", "delete the selection or the rune to the left"},
    .Delete_Forward      = {"edit.delete_forward", "delete the selection or the rune to the right"},
    .Delete_Word_Back    = {"edit.delete_word_back", "delete the word to the left"},
    .Delete_Word_Forward = {"edit.delete_word_forward", "delete the word to the right"},
    .Newline             = {"edit.newline", "split the line at the caret"},
    .Tab                 = {"edit.tab", "insert a tab"},
    .Select_All          = {"edit.select_all", "one selection over the whole document"},
    .Select_Expand       = {"select.expand", "select what point sits in, at the document's own granularity"},
    .Cursor_Add          = {"cursor.add", "a caret under the pointer, keeping the ones already up"},
    .Cursor_Add_Below    = {"cursor.add_below", "a caret on the line under the lowest one"},
    .Cursor_Add_Above    = {"cursor.add_above", "a caret on the line over the highest one"},
    .Cursor_Add_Next     = {"cursor.add_next_match", "select the word under point, then a caret over each next match of it"},
    .Cursor_Add_All      = {"cursor.add_all_matches", "the same seed, then a caret over every match at once"},
    .Cursor_Split        = {"cursor.split_lines", "one caret per line of each selection"},
    .Cursor_Collapse     = {"cursor.collapse", "put the trail down; only the primary caret is left"},
    .View_Scroll_Up      = {"view.scroll_up", "scroll the view toward the start; point stays put"},
    .View_Scroll_Down    = {"view.scroll_down", "scroll the view toward the end; point stays put"},
    .View_Page_Up        = {"view.page_up", "scroll the view back one screenful; point stays put"},
    .View_Page_Down      = {"view.page_down", "scroll the view on one screenful; point stays put"},
    .Cut                 = {"edit.cut", "cut the selection, or the line, to the clipboard"},
    .Copy                = {"edit.copy", "copy the selection, or the line, to the clipboard"},
    .Paste               = {"edit.paste", "insert what the clipboard holds"},
    .Paste_Cycle         = {"edit.paste_cycle", "replace the last paste with the entry before it"},
    .Kill_Line           = {"edit.kill_line", "kill from the caret to the end of the line"},
    .Kill_Whole_Line     = {"edit.kill_whole_line", "kill the line the caret is on"},
    .Kill_To_Line_Start  = {"edit.kill_to_line_start", "kill from the caret back to the start of the line"},
    .Search_Next         = {"search.next", "the next match of the last search, wrapping"},
    .Search_Prev         = {"search.prev", "the match before it, wrapping the other way"},
    .Save                = {"file.dump", "write the focused document into oket's state directory, whatever opened it"},
    .Undo                = {"edit.undo", "undo the last step"},
    .Redo                = {"edit.redo", "redo the last undone step"},
    .Ring_Goto           = {"ring.goto", "go to slot N"},
    .Ring_Alt            = {"ring.alt", "toggle the two most recent surfaces, whatever ring they are in"},
    .Ring_Alt_Lane       = {"ring.alt_lane", "the same toggle, kept inside the ring you are in"},
    .Ring_Close          = {"ring.close", "close the focused slot and the panel with it; its number is never reused while others live"},
    .Ring_Zero           = {"ring.zero", "go to N0, the terminal oket runs things in"},
    .Panel_Open          = {"panel.open", "a panel to the right of this one, standing on nothing"},
    .Panel_Close         = {"panel.close", "close the focused panel; what was in it stays in the ring"},
    .Panel_Next          = {"panel.next", "focus the panel to the right"},
    .Panel_Prev          = {"panel.prev", "focus the panel to the left"},
    .Panel_Move_Left     = {"panel.move_left", "swap this panel with the one to its left"},
    .Panel_Move_Right    = {"panel.move_right", "swap this panel with the one to its right"},
    .Jump_Back           = {"jump.back", "to the previous position in the jump ring, across surfaces"},
    .Jump_Forward        = {"jump.forward", "back toward the position you jumped from"},
    .CL_Open             = {"cl.open", "open the command line"},
    .CL_Sigil            = {"cl.sigil", "open the command line with the builtin : typed"},
    .Menu_Open           = {"menu.open", "open the menubar on its first menu"},
    .Surface_Send        = {"surface.send", "send the key to the focused surface's own job"},
    .Term_Copy           = {"term.copy", "copy the selection, or the line point is on, to the system clipboard"},
    .Term_Paste          = {"term.paste", "paste the clipboard as bracketed input"},
    .Font_Bigger         = {"font.bigger", "one step up in cell size; the grid holds fewer"},
    .Font_Smaller        = {"font.smaller", "one step down in cell size; the grid holds more"},
    .Font_Reset          = {"font.reset", "back to the size the system asked for"},
}

// A second spelling, for the few verbs that have one.
@(rodata)
COMMAND_ALSO := #partial [Command]string {
    .Quit       = "q",
    .Panel_Open = "np",
}

// A verb by its registry name, which is the name the config, `:` and describe all use, so the
// three can never disagree about what a verb is called (§6).
command_named :: proc(name: string) -> (Command, bool) {
    for info, cmd in COMMANDS {
        if cmd != .None && (info.name == name || name != "" && COMMAND_ALSO[cmd] == name) {
            return cmd, true
        }
    }
    return .None, false
}

// The name in a line that is one `:name` and nothing else.
lone_verb :: proc(line: string) -> (string, bool) {
    if !strings.has_prefix(line, ":") || strings.contains_any(line, " \t") {
        return "", false
    }
    return line[1:], true
}

// The verb a lone `:verb` line names, for the callers that act on the verb before the line runs.
line_command :: proc(line: string) -> (cmd: Command, ok: bool) {
    name := lone_verb(line) or_return
    return command_named(name)
}

// A verb that places its own point. The kernel moves point to the cell under the pointer before
// it dispatches a button chord (§8), and for these that move would take down the very carets the
// verb exists to add to — so the press skips it, and describe says `runs` instead of `moves
// point, then runs`.
command_places_point :: proc(c: Command) -> bool {
    return c == .Cursor_Add
}

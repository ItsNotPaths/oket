package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../desc"
import "../store"

// The ring, across restarts (§14). `[session] restore` in config.odin is what turns it on.
//
// A SESSION IS A LIST OF COMMAND LINES. Restoring it is running them, so there is no session
// format to version and nothing in here the user could not have typed. A document with no
// `file` is not written: a terminal's session is a process that ended with the last start, and
// a home page is built from what the next start finds, not from what the last one saw.
//
// Off by default. A start that reopens what you closed the hard way is worse than a start that
// does nothing, and `--safe` ignores the file for the case the session is what breaks you.

SESSION_NAME :: "session"

// Written at a clean exit, which is the only kind that has anything to say: a crash leaves
// journals instead, and those are the work rather than the layout (journal.odin).
//
// The strip is in the file too, as the `@N` on a line (PANELS.md §11's question): a layout is
// panels standing on slots, and both halves are addresses the user could have typed. Slots no
// panel is standing on go FIRST, because a line with no `@` aims the focused panel and one of
// those running after the strip was built would drag it about.
session_save :: proc(a: ^App) {
    if !a.config.restore || a.home.state == "" {
        return
    }
    b := strings.builder_make(context.temp_allocator)
    for l, lane in a.ring.lanes {
        for s, i in l.slots {
            if s.live && panel_showing(a, {lane, i + 1}) == nil {
                session_line(a, &b, s.doc, i + 1, 0)
            }
        }
    }
    // The focused panel last, because `:open` focuses what it opens: the layout restores in one
    // pass and the surface you were looking at is the one you come back to.
    for _, i in a.panels {
        if i != a.focus {
            session_panel(a, &b, i)
        }
    }
    session_panel(a, &b, a.focus)
    _ = os.write_entire_file(session_path(a), transmute([]u8)strings.to_string(b))
}

// A panel, as the line that puts a document back under it. A panel standing on nothing, or on a
// document with no file, writes nothing: a terminal's session is a process that ended with the
// last start, and so is the panel that held it.
@(private = "file")
session_panel :: proc(a: ^App, b: ^strings.Builder, i: int) {
    p := panel_get(a, i)
    if p == nil || p.at.slot < 1 {
        return
    }
    if s := panel_slot(a, p); s != nil {
        session_line(a, b, s.doc, p.at.slot, i + 1)
    }
}

// Every line, as though it had been typed. Answers whether anything opened, so a start knows
// if the ring is still empty.
session_restore :: proc(a: ^App) -> bool {
    if !a.config.restore || a.home.state == "" {
        return false
    }
    raw, err := os.read_entire_file(session_path(a), context.temp_allocator)
    if err != nil {
        return false
    }
    text := string(raw)
    for line in strings.split_lines_iterator(&text) {
        if strings.trim_space(line) != "" {
            cl_exec(a, line)
        }
    }
    return ring_focused(a) != nil
}

// One `:open`, with the sigils on: a bare number still means `#N`, and a written row says which
// axis it is on (§4).
@(private = "file")
session_line :: proc(a: ^App, b: ^strings.Builder, id: store.Id, slot, panel: int) {
    d := store.store_descriptor(&a.docs, id)
    if d == nil {
        return
    }
    defer desc.release(d)
    if d.file == "" {
        return
    }
    at := panel > 0 ? fmt.tprintf(" @%d", panel) : ""
    fmt.sbprintfln(b, ":open %s #%d%s", sh_quote(d.file, context.temp_allocator), slot, at)
}

@(private = "file")
session_path :: proc(a: ^App) -> string {
    path, _ := filepath.join({a.home.state, SESSION_NAME}, context.temp_allocator)
    return path
}

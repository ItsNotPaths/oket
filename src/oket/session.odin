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
session_save :: proc(a: ^App) {
    if !a.config.restore || a.home == "" {
        return
    }
    b := strings.builder_make(context.temp_allocator)
    focused := ring_focused(a)
    for l in a.ring.lanes {
        for s, i in l.slots {
            if !s.live || (focused != nil && s.doc == focused.doc) {
                continue
            }
            session_line(a, &b, s.doc, i + 1)
        }
    }
    // The focused slot last, because `:open` focuses what it opens: the layout restores in one
    // pass and the surface you were looking at is the one you come back to.
    if focused != nil {
        session_line(a, &b, focused.doc, ring_slot(a))
    }
    _ = os.write_entire_file(session_path(a), transmute([]u8)strings.to_string(b))
}

// Every line, as though it had been typed. Answers whether anything opened, so a start knows
// if the ring is still empty.
session_restore :: proc(a: ^App) -> bool {
    if !a.config.restore || a.home == "" {
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

@(private = "file")
session_line :: proc(a: ^App, b: ^strings.Builder, id: store.Id, slot: int) {
    d := store.store_descriptor(&a.docs, id)
    if d == nil {
        return
    }
    defer desc.release(d)
    if d.file == "" {
        return
    }
    fmt.sbprintfln(b, ":open %s %d", sh_quote(d.file, context.temp_allocator), slot)
}

@(private = "file")
session_path :: proc(a: ^App) -> string {
    path, _ := filepath.join({a.home, SESSION_NAME}, context.temp_allocator)
    return path
}

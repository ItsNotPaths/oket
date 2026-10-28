package main

import "core:fmt"
import "core:strings"
import "lues:lues"
import "../desc"
import "../input"
import "../store"

// A ring lane is a KIND (§5). The table below is the only place a kind's name is written down,
// so `binds.conf`'s `[files]` section, `:ring files` and what `:ls` prints are one string and
// cannot drift. No kernel code compares a kind NAME: it compares identity, and the name is a
// display and config read.
//
// input.Kind(0) is no kind — a document in no lane, whose keys are `[text]`'s. The kernel's own
// two are written here in a fixed order so they are constants; a plugin's kind appends past them
// in lues (kind_base) and nothing about this shape changes.
//
// THE TWO LEFT HERE ARE THE ONES THE KERNEL IS. A terminal is a PTY the kernel owns and a home
// page is what a start has to say for itself; both are the kernel's own state, and neither is a
// path on disk. Everything a PATH becomes is a plugin — `edit` for a file, `files` for a
// directory — because a kernel that opened one would be the privileged path §7 forbids.

@(rodata)
KINDS := [?]string{"term", "home"}

KIND_TERM :: input.Kind(1)
KIND_HOME :: input.Kind(2)

// The two kinds `:open` hands a path to. NAMES, not privileges: whoever registers one gets the
// paths, and with nobody registered the kernel says so rather than opening one itself.
//
// There is no kernel listing behind `files` and no kernel editor behind `edit`. A directory and
// a file are the same question, and answering half of it in the kernel is the privileged path
// §7 forbids — and a `files` document no plugin owns takes every `[files]` row while being able
// to answer none of them.
KIND_EDIT :: "edit"
KIND_BROWSE :: "files"

kind_named :: proc(a: ^App, name: string) -> (input.Kind, bool) {
    for k, i in KINDS {
        if k == name {
            return input.Kind(i + 1), true
        }
    }
    kind, ok := lues.kind_named(a.kernel, name)
    return input.Kind(kind), ok
}

// "" for no kind and for a kind nobody registered, which is what `:ls` prints for a document
// that belongs to no lane.
kind_name :: proc(a: ^App, kind: input.Kind) -> string {
    i := int(kind) - 1
    if i >= 0 && i < len(KINDS) {
        return KINDS[i]
    }
    if k, ok := plug_kind(a, kind); ok {
        return k.name
    }
    return ""
}

// A fresh document of a kind, for `alt+N` on an empty slot: the lane already names the kind, so
// the kernel picks nothing (§5). The two arms are the kernel's own; every other kind answers
// this with the `open` message, which is the whole of what a plugin has to implement to own a
// lane.
kind_fresh :: proc(a: ^App, kind: input.Kind) -> (store.Id, bool) {
    if _, owned := plug_kind(a, kind); owned {
        return plug_open(a, kind)
    }
    switch kind {
    case KIND_TERM:
        return term_open(a)
    case KIND_HOME:
        return home_open(a), true
    }
    return {}, false
}

// What a DIRECTORY becomes, the same shape a file's `edit` has: a kind named in one string, and
// a report rather than a listing of the kernel's own when nothing registers it.
files_open :: proc(a: ^App, dir: string) -> (store.Id, bool) {
    kind, registered := kind_named(a, KIND_BROWSE)
    if !registered {
        message_set(a, fmt.tprintf(":open: nothing registers the %s kind, so nothing opens a directory (:plug load %s)",
                                   KIND_BROWSE, "files"))
        return {}, false
    }
    return plug_open(a, kind, dir)
}

// The App as a name table, lent to `input`, which holds a line as text and a section as identity
// and never the tables that name them. A lone `:verb` line reads as its verb; any other line,
// or one whose plugin unloaded, reads as itself (§8). A nil App names the kernel's verbs only.
names :: proc(a: ^App) -> input.Names {
    return {
        user = a,
        line = proc(user: rawptr, line: string) -> (name, doc: string, places_point: bool) {
            if cmd, named := line_command(line); named {
                return COMMANDS[cmd].name, COMMANDS[cmd].doc, command_places_point(cmd)
            }
            a := (^App)(user)
            if name, lone := lone_verb(line); lone && a != nil {
                if i, registered := plug_cmd_named(a, name); registered {
                    return a.kernel.cmds[i].name, a.kernel.cmds[i].doc, false
                }
            }
            return line, "run as typed", false
        },
        section = proc(user: rawptr, s: input.Section) -> string {
            return section_name((^App)(user), s)
        },
        path = proc(user: rawptr, s: input.Section) -> []input.Section {
            path, _ := section_path((^App)(user), s)
            return path
        },
    }
}

// --- the table, applied to a document ---

// The lane a document belongs in, which is the kind its descriptor names (§5).
doc_kind :: proc(a: ^App, id: store.Id) -> input.Kind {
    d := store.store_descriptor(a.docs, id)
    if d == nil {
        return 0
    }
    defer desc.release(d)
    return d.kind
}

// What the bar and `:ls` call a document: its file, else its kind. Temp-allocated.
doc_title :: proc(a: ^App, id: store.Id) -> string {
    d := store.store_descriptor(a.docs, id)
    if d == nil {
        return ""
    }
    defer desc.release(d)
    return d.file != "" ? strings.clone(d.file, context.temp_allocator) : kind_name(a, d.kind)
}

// A document's file, as the key two documents are the SAME document by. "" for one that is not
// a path at all — a terminal, a home page, a scratch buffer — and "" is never the same as
// anything.
doc_file :: proc(a: ^App, id: store.Id) -> string {
    d := store.store_descriptor(a.docs, id)
    if d == nil {
        return ""
    }
    defer desc.release(d)
    return path_abs(d.file)
}

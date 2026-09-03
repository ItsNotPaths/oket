package main

import "core:strings"
import "../desc"
import "../input"
import "../store"

// A ring lane is a KIND (§5). The table below is the only place a kind's name is written down,
// so `binds.conf`'s `[files]` section, `:ring files` and what `:ls` prints are one string and
// cannot drift. No kernel code compares a kind NAME: it compares identity, and the name is a
// display and config read.
//
// A kind's DOCUMENT is opened by a file of its own — listing.odin, term.odin — and `kind_fresh`
// below is the only thing that has to know there is more than one.
//
// input.Kind(0) is no kind — a document in no lane, and the wide tier of the bind table. The
// kernel's own two are written here in a fixed order so they are constants: they are the boot
// floor, and the kernel opens with them and no plugins at all (§7). A plugin's kind appends
// past them into `a.kinds` (plug.odin) and nothing about this shape changes.
//
// There is no `text` here: a file in a buffer is an EDITOR, the editor is a plugin, and a
// kernel kind that opened one would be the privileged path §7 forbids.

Kind_Info :: struct {
    name: string,
    ctx:  input.Bind_Ctx, // the context a chord lands in over this kind's documents
}

@(rodata)
KINDS := [?]Kind_Info{{"files", .Surface}, {"term", .Terminal}, {"home", .Surface}}

KIND_FILES :: input.Kind(1)
KIND_TERM :: input.Kind(2)
KIND_HOME :: input.Kind(3)

// The kind `:open` hands a regular file to. A NAME, not a privilege: whoever registers it gets
// the files, and with nobody registered the kernel says so rather than opening one itself.
KIND_EDIT :: "edit"

kind_named :: proc(a: ^App, name: string) -> (input.Kind, bool) {
    for k, i in KINDS {
        if k.name == name {
            return input.Kind(i + 1), true
        }
    }
    for k, i in a.kinds {
        if k.owner >= 0 && k.name == name {
            return input.Kind(len(KINDS) + i + 1), true
        }
    }
    return 0, false
}

// "" for no kind and for a kind nobody registered, which is what `:ls` prints for a document
// that belongs to no lane.
kind_name :: proc(a: ^App, kind: input.Kind) -> string {
    return kind_info(a, kind).name
}

kind_ctx :: proc(a: ^App, kind: input.Kind) -> input.Bind_Ctx {
    return kind_info(a, kind).ctx
}

@(private = "file")
kind_info :: proc(a: ^App, kind: input.Kind) -> Kind_Info {
    i := int(kind) - 1
    if i >= 0 && i < len(KINDS) {
        return KINDS[i]
    }
    if k, ok := plug_kind(a, kind); ok {
        return {k.name, k.ctx}
    }
    return {"", .Global}
}

// A fresh document of a kind, for `alt+N` on an empty slot: the lane already names the kind, so
// the kernel picks nothing (§5). The two arms are the kernel's own; every other kind answers
// this with the `open` message, which is the whole of what a plugin has to implement to own a
// lane.
kind_fresh :: proc(a: ^App, kind: input.Kind) -> (store.Id, bool) {
    switch kind {
    case KIND_FILES:
        return listing_open(a, "."), true
    case KIND_TERM:
        return term_open(a)
    case KIND_HOME:
        return home_open(a), true
    }
    return plug_open(a, kind)
}

// The App as a name table, lent to `input`, which holds a Kind and a Slot as identity and
// never the tables that name them. One reader per table, one borrow. Both stay TOTAL: a kind
// or a command whose plugin unloaded still has to answer, or describe would go quiet on the
// one row a user is most likely to be asking about (§8).
names :: proc(a: ^App) -> input.Names {
    return {
        user = a,
        slot = proc(user: rawptr, slot: input.Slot) -> (name, doc: string) {
            a := (^App)(user)
            i := int(slot)
            if i < 0 || i >= len(a.cmds) || a.cmds[i].owner < 0 {
                return "?", "a command whose plugin is not loaded"
            }
            return a.cmds[i].name, a.cmds[i].doc
        },
        kind = proc(user: rawptr, kind: input.Kind) -> string {
            return kind_name((^App)(user), kind)
        },
    }
}

// --- the table, applied to a document ---

// The lane a document belongs in, which is the kind its descriptor names (§5).
doc_kind :: proc(a: ^App, id: store.Id) -> input.Kind {
    d := store.store_descriptor(&a.docs, id)
    if d == nil {
        return 0
    }
    defer desc.release(d)
    return d.kind
}

// What the bar and `:ls` call a document: its file, else its kind. Temp-allocated.
doc_title :: proc(a: ^App, id: store.Id) -> string {
    d := store.store_descriptor(&a.docs, id)
    if d == nil {
        return ""
    }
    defer desc.release(d)
    return d.file != "" ? strings.clone(d.file, context.temp_allocator) : kind_name(a, d.kind)
}

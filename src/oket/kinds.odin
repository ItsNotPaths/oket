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
// A kind's DOCUMENT is opened by a file of its own — text.odin, listing.odin — and `kind_fresh`
// below is the only thing that has to know there is more than one.
//
// input.Kind(0) is no kind — a document in no lane, and the wide tier of the bind table. The
// kernel's own two are registered here in a fixed order so they are constants; a plugin's kind
// appends past them at stage 7 and nothing about this shape changes.

Kind_Info :: struct {
    name: string,
    ctx:  input.Bind_Ctx, // the context a chord lands in over this kind's documents
}

@(rodata)
KINDS := [?]Kind_Info{{"text", .Text}, {"files", .Surface}}

KIND_TEXT :: input.Kind(1)
KIND_FILES :: input.Kind(2)

kind_named :: proc(name: string) -> (input.Kind, bool) {
    for k, i in KINDS {
        if k.name == name {
            return input.Kind(i + 1), true
        }
    }
    return 0, false
}

// "" for no kind and for a kind nobody registered, which is what `:ls` prints for a document
// that belongs to no lane.
kind_name :: proc(kind: input.Kind) -> string {
    return kind_info(kind).name
}

kind_ctx :: proc(kind: input.Kind) -> input.Bind_Ctx {
    return kind_info(kind).ctx
}

@(private = "file")
kind_info :: proc(kind: input.Kind) -> Kind_Info {
    i := int(kind) - 1
    return i >= 0 && i < len(KINDS) ? KINDS[i] : Kind_Info{"", .Global}
}

// A fresh document of a kind, for `alt+N` on an empty slot: the lane already names the kind, so
// the kernel picks nothing (§5). Both arms here are the kernel's own; a plugin kind answers
// this with the `open` message at stage 7.
kind_fresh :: proc(a: ^App, kind: input.Kind) -> (store.Id, bool) {
    switch kind {
    case KIND_TEXT:
        return text_open(&a.docs, ""), true
    case KIND_FILES:
        return listing_open(&a.docs, "."), true
    }
    return {}, false
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
    return d.file != "" ? strings.clone(d.file, context.temp_allocator) : kind_name(d.kind)
}

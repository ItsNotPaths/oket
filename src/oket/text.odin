package main

import "../desc"
import "../store"

// The text kind's document: a file's bytes, or empty for a scratch. One file per kind that the
// kernel opens itself, beside listing.odin, and `kind_fresh` is the only thing that has to know
// there are two.

// `editable` because the KERNEL edits it through its own text ops (§12); self-insert still waits
// for stage 8's editor.
text_open :: proc(s: ^store.Store, path: string, text := "") -> store.Id {
    id := store.store_open(s, text)
    gen, _ := store.store_gen(s, id)
    d := desc.new_from(
        {
            numbers = .Absolute,
            ctx = kind_ctx(KIND_TEXT),
            kind = KIND_TEXT,
            file = path,
            selection = .Char,
            editable = true,
            tab_width = 4,
        },
    )
    store.store_submit(s, id, gen, nil, d)
    desc.release(d)
    store.store_drain(s)
    return id
}

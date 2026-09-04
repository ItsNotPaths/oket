package main

import "core:slice"
import "core:strings"
import "../store"

// WHO publishes a style run (§8). THE PRODUCER IS THE LAYER: a publisher owns a bucket in the
// span store under its own name — a plugin's is its plugin's, the terminal's is `term` — so
// nobody can range-replace anybody else's colours, whatever they are compiled to say.
//
// The store keys by the id and never sees the name; `[<kind>] spans = a, b, c` in config.conf
// ranks the names, and that is the z-order the renderer reads them in.

TERM_PRODUCER :: "term" // the kernel's own publisher (term.odin), named so config can rank it

// The id for `name`, the same id for the same name whoever asks — the table tokens.odin keeps
// for style names, one vocabulary over. A reload gets its old id back, so a config line that
// ranks a plugin goes on meaning what it said.
//
// Interned by PUBLISHING, so the table is what has had an opinion about a document, not what is
// loaded: an unloaded plugin keeps its slot and gets its runs back if it comes home.
producer_intern :: proc(a: ^App, name: string) -> store.Producer {
    if who, known := producer_find(a, name); known {
        return who
    }
    append(&a.producers, strings.clone(name))
    return store.Producer(len(a.producers) - 1)
}

// The id a name already has. What unload asks: a plugin that never published must not be given
// a bucket on its way out.
producer_find :: proc(a: ^App, name: string) -> (store.Producer, bool) {
    for p, i in a.producers {
        if p == name {
            return store.Producer(i), true
        }
    }
    return 0, false
}

producer_name :: proc(a: ^App, who: store.Producer) -> string {
    i := int(who)
    return i >= 0 && i < len(a.producers) ? a.producers[i] : ""
}

producers_destroy :: proc(a: ^App) {
    for p in a.producers {
        delete(p)
    }
    delete(a.producers)
    a.producers = nil
}

// The z-order for this document, lowest first: what its kind's config line names, in the order
// it names them, then everybody else by name.
//
// UNNAMED DRAWS ON TOP, which is the arm worth stating. A file ranks the publishers a user has
// an opinion about; one it has never heard of is more useful visible than buried, and a search
// plugin installed tomorrow must not come up invisible under a parser named today.
spans_order :: proc(a: ^App, id: store.Id, alloc := context.temp_allocator) -> []store.Producer {
    out := make([dynamic]store.Producer, 0, len(a.producers), alloc)
    for name in config_spans(&a.config, kind_name(a, doc_kind(a, id))) {
        for p, i in a.producers {
            if p == name {
                append(&out, store.Producer(i))
            }
        }
    }
    rest := make([dynamic]store.Producer, 0, len(a.producers), context.temp_allocator)
    for _, i in a.producers {
        if !slice.contains(out[:], store.Producer(i)) {
            append(&rest, store.Producer(i))
        }
    }
    producers_sort(a, rest[:])
    append(&out, ..rest[:])
    return out[:]
}

// --- internals ---

// By NAME, which needs the table the ids index. Insertion sort: the list is one entry per
// publisher a session has ever had, so it is short and this runs once per drawn document.
@(private = "file")
producers_sort :: proc(a: ^App, list: []store.Producer) {
    for i in 1 ..< len(list) {
        p := list[i]
        j := i
        for ; j > 0 && producer_name(a, list[j - 1]) > producer_name(a, p); j -= 1 {
            list[j] = list[j - 1]
        }
        list[j] = p
    }
}

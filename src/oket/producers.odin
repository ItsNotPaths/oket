package main

import "core:slice"
import "lues:lues"
import "../store"

// Who publishes style runs (§8). lues interns the names a span bucket is keyed by; config ranks
// them by name, so the z-order is a file and not a load order.

TERM_PRODUCER :: "term" // the kernel's own publisher (term.odin), named so config can rank it

producer_intern :: proc(a: ^App, name: string) -> store.Producer {
    return lues.producer_intern(a.kernel, name)
}

producer_find :: proc(a: ^App, name: string) -> (store.Producer, bool) {
    return lues.producer_find(a.kernel, name)
}

producer_name :: proc(a: ^App, who: store.Producer) -> string {
    return lues.producer_name(a.kernel, who)
}

// The z-order for this document, lowest first: what its kind's config line names, in the order
// it names them, then everybody else by name.
//
// UNNAMED DRAWS ON TOP, which is the arm worth stating. A file ranks the publishers a user has
// an opinion about; one it has never heard of is more useful visible than buried, and a search
// plugin installed tomorrow must not come up invisible under a parser named today.
spans_order :: proc(a: ^App, id: store.Id, alloc := context.temp_allocator) -> []store.Producer {
    names := a.kernel.producers[:]
    out := make([dynamic]store.Producer, 0, len(names), alloc)
    for name in config_names(&a.config, kind_name(a, doc_kind(a, id)), "spans") {
        if i, found := slice.linear_search(names, name); found {
            append(&out, store.Producer(i))
        }
    }
    rest := make([dynamic]store.Producer, 0, len(names), context.temp_allocator)
    for _, i in names {
        if !slice.contains(out[:], store.Producer(i)) {
            append(&rest, store.Producer(i))
        }
    }
    // By NAME. Insertion sort: one entry per publisher a session has ever had.
    for i in 1 ..< len(rest) {
        p := rest[i]
        j := i
        for ; j > 0 && names[rest[j - 1]] > names[p]; j -= 1 {
            rest[j] = rest[j - 1]
        }
        rest[j] = p
    }
    append(&out, ..rest[:])
    return out[:]
}

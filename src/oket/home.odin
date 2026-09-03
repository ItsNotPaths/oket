package main

import "core:fmt"
import "core:strings"
import "../desc"
import "../store"
import "../txt"

// The home page (§13): what the kernel has to tell you at a start, as a document rather than as
// a screen. Work a crash left behind, and the plugins that crash took with them.
//
// A DOCUMENT because it is acted on. `enter` over a row of recovered work takes it back, and
// that is one `binds.conf` row over one field — the same shape a listing's `enter` has, so
// recovery needs no key job, no dialog and no mode. screen.odin stays what it was: the floor
// with nothing focused, which is a different question.
//
// It opens only when there is news. A start that has nothing to report opens a listing, and
// `:home` asks for the page whenever you want it.

home_open :: proc(a: ^App) -> store.Id {
    id := store.store_open(&a.docs)
    home_fill(a, id)
    return id
}

// Every open home page, rewritten. What it lists is the state of two directories, so a recover
// or a `:plug load` has to be visible without closing the page that offered it.
home_refresh :: proc(a: ^App) {
    for id in store.store_ids(&a.docs) {
        if doc_kind(a, id) == KIND_HOME {
            home_fill(a, id)
        }
    }
}

home_news :: proc(a: ^App) -> bool {
    return len(recover_scan(a)) > 0 || len(a.quarantined) > 0
}

// The page as it is being written: the bytes, the spans named in them, and how many lines are
// down. One struct rather than three pointers threaded through every call.
@(private = "file")
Page :: struct {
    text:   strings.Builder,
    fields: [dynamic]desc.Field,
    line:   int,
}

@(private = "file")
say :: proc(p: ^Page, s: string) {
    if p.line > 0 {
        strings.write_rune(&p.text, '\n')
    }
    strings.write_string(&p.text, s)
    p.line += 1
}

// A row: two spaces, the value a bind acts on, then whatever else the line says. The value is a
// span of the line's own bytes, which is all `fields` ever is (§5), so hover underlines exactly
// what `enter` would take.
@(private = "file")
row :: proc(p: ^Page, name, value, tail: string) {
    at := 2
    say(p, fmt.tprintf("  %s%s", value, tail))
    append(&p.fields, desc.Field{p.line - 1, name, at, at + len(value)})
}

@(private = "file")
home_fill :: proc(a: ^App, id: store.Id) {
    p := Page {
        text   = strings.builder_make(context.temp_allocator),
        fields = make([dynamic]desc.Field, context.temp_allocator),
    }
    say(&p, fmt.tprintf("oket %s", version_text()))

    if work := recover_scan(a); len(work) > 0 {
        say(&p, "")
        say(&p, "unsaved work a crash left behind — enter takes it back:")
        for r in work {
            row(&p, "path", r.path, fmt.tprintf("   %d edit(s)", r.edits))
        }
        say(&p, "  (:recover drop <path> throws one away)")
    }

    // `plug` is named for the same reason `size` is named in a tree the browser never draws it
    // in: no kernel row reads it, and a `[home] delete = exec :plug load <plug>` in binds.conf
    // would, without this file learning a second verb.
    if len(a.quarantined) > 0 {
        say(&p, "")
        say(&p, "plugins that took a start down, and are not loaded:")
        for name in a.quarantined {
            row(&p, "plug", name, "")
        }
        say(&p, "  (:plug load <name> takes one again, once it is fixed)")
    }

    say(&p, "")
    say(&p, "alt+f files   alt+t term   alt+c command line   f1 describes a chord")

    doc := store.store_doc(&a.docs, id)
    if doc == nil {
        return
    }
    gen := doc.gen
    d := desc.new_from(
        {
            ctx = kind_ctx(a, KIND_HOME),
            kind = KIND_HOME,
            selection = .Line,
            tab_width = 4,
            fields = p.fields[:],
        },
    )
    whole := txt.Edit{0, txt.doc_len(doc), strings.to_string(p.text), 0}
    store.store_submit(&a.docs, id, gen, {whole}, d)
    desc.release(d)
    store.store_drain(&a.docs)
}

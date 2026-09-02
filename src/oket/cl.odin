package main

import "core:strings"
import "../desc"
import "../gfx"
import "../input"
import "../store"
import "../txt"
import "../view"

// The command line (§11): one row at the bottom of the screen, and a real editable document
// like any other. Motions, selection and the delete verbs serve it through the same bind table
// and the same renderer a document gets, which is why there is no second set of key code for
// it — `active` in routing.odin is the whole of the trick.
//
// Bare text is a shell command, a leading `:` is a builtin, and a submitted line is an `&&`
// chain of both (chain.odin runs it, builtins.odin answers the sigil). Kernel-owned, so it
// works with zero plugins loaded, which is what makes it the recovery floor (§7).

CL_PROMPT :: "> "

Cmdline :: struct {
    using slot: Slot,
    history:    [dynamic]string, // owned
    hist_idx:   int, // == len(history) is the live edit
}

cl_init :: proc(a: ^App) {
    if a.cl.live {
        return
    }
    a.cl.doc = store.store_open(&a.docs, "")
    a.cl.live = true
    gen, _ := store.store_gen(&a.docs, a.cl.doc)
    // A widget, not a surface (§5): no kind, so it takes no ring slot and appears in no lane.
    d := desc.new_from({ctx = .Text, selection = .Char, editable = true, tab_width = 4})
    store.store_submit(&a.docs, a.cl.doc, gen, nil, d)
    desc.release(d)
    store.store_drain(&a.docs)
}

cl_destroy :: proc(a: ^App) {
    if a.cl.live {
        store.store_close(&a.docs, a.cl.doc)
    }
    for h in a.cl.history {
        delete(h)
    }
    delete(a.cl.history)
    a.cl = {}
}

// Open IS the pending state: modal, drawn on the bar row, and Escape closes it at any depth.
cl_active :: proc(a: ^App) -> bool {
    _, open := a.pending.(input.Pending_Cmdline)
    return open
}

// Open the line, optionally with text already typed — alt+; passes the `:` sigil, and a bind
// line's `stage` passes the whole expanded line.
cl_show :: proc(a: ^App, prefix := "") {
    cl_init(a) // a zero Id resolves to whatever took slot 0, so the line owns its document first
    a.pending = input.Pending_Cmdline{}
    cl_set(a, prefix)
    a.cl.hist_idx = len(a.cl.history)
}

cl_hide :: proc(a: ^App) {
    a.pending = nil
    cl_set(a, "")
}

// What is typed right now, trimmed the way submit trims it.
cl_line :: proc(a: ^App, alloc := context.temp_allocator) -> string {
    doc := store.store_doc(&a.docs, a.cl.doc)
    if doc == nil {
        return ""
    }
    return strings.trim_space(txt.doc_string(doc, alloc))
}

cl_submit :: proc(a: ^App) {
    line := cl_line(a) // its own copy already: doc_string reads the rope out
    cl_hide(a)
    if line == "" {
        return
    }
    append(&a.cl.history, strings.clone(line))
    cl_exec(a, line)
}

// The four chords the line answers for itself. Everything else falls through to the ordinary
// dispatch, which acts on the line because `active` says the line is the document now.
cl_take :: proc(a: ^App, cmd: input.Command) -> bool {
    #partial switch cmd {
    case .Quit:
        cl_hide(a)
    case .Newline:
        cl_submit(a)
    case .Nav_Up:
        cl_history(a, -1)
    case .Nav_Down:
        cl_history(a, +1)
    case:
        return false
    }
    return true
}

// Back through what was run, and forward to the live edit again. One step, either way.
cl_history :: proc(a: ^App, by: int) {
    at := clamp(a.cl.hist_idx + by, 0, len(a.cl.history))
    if at == a.cl.hist_idx {
        return
    }
    a.cl.hist_idx = at
    cl_set(a, at == len(a.cl.history) ? "" : a.cl.history[at])
}

@(private = "file")
cl_set :: proc(a: ^App, text: string) {
    doc := store.store_doc(&a.docs, a.cl.doc)
    if doc == nil {
        return
    }
    txt.doc_set_text(doc, text)
    txt.doc_cursor_to_end(doc)
    a.cl.view.left = 0
    point_sync(a)
}

// The bar row while the line is open: the prompt, then the document, drawn by the one renderer.
cl_draw :: proc(a: ^App, g: ^gfx.Grid, th: gfx.Theme) {
    b := a.bar
    gfx.grid_write(g, b.x - len(CL_PROMPT), b.y, CL_PROMPT, th[.Accent], th[.Bg])
    snap := store.store_snapshot(&a.docs, a.cl.doc)
    if snap == nil {
        return
    }
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, a.cl.doc)
    defer desc.release(d)
    view.follow_col(&a.cl.view, view.point_col(&snap.text, d, a.cl.view), b.w)
    view.draw(g, th, &snap.text, d, a.cl.view, b.x, b.y, b.w, 1)
}

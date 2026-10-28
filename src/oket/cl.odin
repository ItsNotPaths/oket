package main

import "lues:lues"
import "lues:pt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "../desc"
import "../gfx"
import "../input"
import "../cl"
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
    gen:        u64, // the line's generation the live re-run last saw
    due:        time.Tick, // when the live re-run fires; zero is none
    before:     Before,
}

// The focused panel as it stood before the line's first live run. Every run starts from it and
// closing the line puts it back, so a preview never leaves carets behind.
Before :: struct {
    doc:     store.Id,
    view:    view.View,
    cursors: []txt.Cursor, // owned; nil is nothing held
    primary: int,
}

// How long typing pauses before a live step re-runs.
LIVE_DEBOUNCE :: 120 * time.Millisecond

// `[cmdline] live`: the builtins whose step re-runs as you type.
LIVE_SECTION :: "cmdline"
LIVE_DEFAULT :: "find"

cl_init :: proc(a: ^App) {
    if a.cl.live {
        return
    }
    a.cl.doc = store.store_open(a.docs, "")
    a.cl.live = true
    gen, _ := store.store_gen(a.docs, a.cl.doc)
    // A widget, not a surface (§5): no kind, so it takes no ring slot and appears in no lane.
    d := desc.new_from({selection = .Char, editable = true, tab_width = 4})
    store.store_submit(a.docs, a.cl.doc, gen, nil, d)
    desc.release(d)
    lues.kernel_settle(a.kernel)
}

cl_destroy :: proc(a: ^App) {
    if a.cl.live {
        store.store_close(a.docs, a.cl.doc)
    }
    for h in a.cl.history {
        delete(h)
    }
    delete(a.cl.history)
    cl_before_drop(a)
    a.cl = {}
}

// Open IS the pending state: modal, drawn on the bar row, and Escape closes it at any depth.
cl_active :: proc(a: ^App) -> bool {
    _, open := a.pending.(input.Pending_Cmdline)
    return open
}

// Open the line, optionally with text already typed — alt+; passes the `:` sigil, and a bind
// line's `:stage` passes the whole expanded line.
cl_show :: proc(a: ^App, prefix := "") {
    cl_init(a) // a zero Id resolves to whatever took slot 0, so the line owns its document first
    input.pending_set(&a.pending, input.Pending_Cmdline{})
    cl_set(a, prefix)
    a.cl.hist_idx = len(a.cl.history)
}

cl_hide :: proc(a: ^App) {
    input.pending_set(&a.pending)
    cl_set(a, "")
    cl_before_put(a)
    cl_before_drop(a)
    a.cl.due = {}
}

// What is typed right now, trimmed the way submit trims it.
cl_line :: proc(a: ^App, alloc := context.temp_allocator) -> string {
    doc := store.store_doc(a.docs, a.cl.doc)
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

// Step 1 re-runs once typing pauses, when its verb is on `[cmdline] live`.
cl_live_pump :: proc(a: ^App) {
    if !cl_active(a) {
        return
    }
    now := time.tick_now()
    if gen, _ := store.store_gen(a.docs, a.cl.doc); gen != a.cl.gen {
        a.cl.gen = gen
        a.cl.due = time.tick_add(now, LIVE_DEBOUNCE)
    }
    if a.cl.due != {} && time.tick_diff(a.cl.due, now) >= 0 {
        a.cl.due = {}
        line_live(a, cl_line(a))
    }
}

// How long the idle wait may block before the live re-run is due; -1 is no deadline.
cl_live_wait_ms :: proc(a: ^App) -> i32 {
    if a.cl.due == {} {
        return -1
    }
    left := time.tick_diff(time.tick_now(), a.cl.due)
    return i32(max(math.ceil(time.duration_milliseconds(left)), 0))
}

cl_live_listed :: proc(a: ^App, verb: string) -> bool {
    names := config_names(&a.config, LIVE_SECTION, "live")
    return names == nil ? verb == LIVE_DEFAULT : slice.contains(names, verb)
}

// Taken once, before the first live run.
cl_before_hold :: proc(a: ^App) {
    s := ring_focused(a)
    if a.cl.before.cursors != nil || s == nil {
        return
    }
    doc := store.store_doc(a.docs, s.doc)
    if doc == nil {
        return
    }
    a.cl.before = {s.doc, s.view, slice.clone(doc.cursors[:]), doc.primary}
}

cl_before_put :: proc(a: ^App) {
    b := a.cl.before
    s := ring_focused(a)
    if b.cursors == nil || s == nil || s.doc != b.doc {
        return
    }
    if doc := store.store_doc(a.docs, s.doc); doc != nil {
        txt.doc_set_cursors(doc, b.cursors, b.primary)
        s.view = b.view
    }
}

cl_before_drop :: proc(a: ^App) {
    delete(a.cl.before.cursors)
    a.cl.before = {}
}

// The four chords the line answers for itself. Everything else falls through to the ordinary
// dispatch, which acts on the line because `active` says the line is the document now.
cl_take :: proc(a: ^App, cmd: Command) -> bool {
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
    doc := store.store_doc(a.docs, a.cl.doc)
    if doc == nil {
        return
    }
    txt.doc_set_text(doc, text)
    txt.doc_cursor_to_end(doc)
    a.cl.view.left = 0
    point_sync(a)
}

// The bar row while the line is open: the prompt, the document drawn by the one renderer, then
// the workspace right of it.
cl_draw :: proc(a: ^App, g: ^gfx.Grid, th: gfx.Theme, workspace: string) {
    b := a.bar
    line := bar_theme(th)
    cl_fill(g, line, b.y)
    gfx.grid_write(g, b.x - len(CL_PROMPT), b.y, CL_PROMPT, line[.Fg], gfx.opaque(line[.Bg]))
    snap := store.store_snapshot(a.docs, a.cl.doc)
    if snap == nil {
        return
    }
    defer pt.snapshot_release(snap)
    d := store.store_descriptor(a.docs, a.cl.doc)
    defer desc.release(d)
    view.follow_col(&a.cl.view, view.point_col(&snap.text, d, a.cl.view), b.w)
    // Through the pipeline like a panel (VIEWS.md §5): the line has no stages of its own, but
    // the preedit ghost is one, and a composition typed at the prompt has to show there.
    t, dv := views_text(a, a.cl.doc, &snap.text)
    fields := shown_fields(a, a.cl.doc, t, dv, a.cl.view.top, 1)
    view.draw(g, line, t, d, fields, a.cl.view, b.x, b.y, b.w, 1,
              doc_styles(a, a.cl.doc, t, dv, a.cl.view.top, 1), dv = dv,
              select = a.config.select, atlas = &a.painter.atlas)
    gfx.grid_write(g, b.x + b.w, b.y, workspace, line[.Dim], gfx.opaque(line[.Bg]))
}

// Where N0 stands, `~` for $HOME, padded off the typing.
cl_workspace :: proc(a: ^App) -> string {
    dir := term_dir(a)
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" && (dir == home || strings.has_prefix(dir, home) && dir[len(home)] == '/') {
        dir = strings.concatenate({"~", dir[len(home):]}, context.temp_allocator)
    }
    return strings.concatenate({"  ", dir, " "}, context.temp_allocator)
}

// The line's own flat field. Nothing else fills the row: at rest it is a frame box (bar.odin).
@(private = "file")
cl_fill :: proc(g: ^gfx.Grid, th: gfx.Theme, row: int) {
    for x in 0 ..< g.cols {
        gfx.grid_put(g, x, row, gfx.Cell{' ', th[.Fg], gfx.opaque(th[.Bg]), {}, 0})
    }
}

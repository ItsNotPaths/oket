package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:glfw"
import "../gfx"
import "../input"
import "../store"
import "../work"

// The kernel's whole mutable state: one window, a store of documents, the ring that says which
// one is on screen, one bind table, and the command line.

App :: struct {
    window:       glfw.WindowHandle,
    painter:      gfx.Painter,
    // Two lattices, not one (PANELS.md §7). The chrome is the screen's, at whole cells: the
    // bar, and the ground a panel is drawn onto. The panel is a window onto a document and
    // takes an origin of its own, so it can slide without dragging the bar with it.
    chrome:       gfx.Grid,
    panel:        gfx.Grid,
    theme:        gfx.Theme,
    docs:         store.Store,
    ring:         Ring,
    // Every live PTY session, by the document it drives. A terminal is a kernel-implemented
    // document (§7), so what a session needs past text and a descriptor lives here and not in
    // the store.
    terms:        map[store.Id]^Term,
    // The plugin seam (§7). One vtable behind one pointer, a table per registration, and the
    // instance a plugin's document carries. Slots are tombstoned rather than compacted, so an
    // id a bind row or a descriptor holds never means someone else.
    api:          Api_Box,
    plugs:        [dynamic]Plugin,
    kinds:        [dynamic]Plug_Kind,
    cmds:         [dynamic]Plug_Cmd,
    insts:        map[store.Id]Plug_Inst,
    // §9's I/O workers, and the record of who a job's answers belong to. The pool holds the
    // one thread that waits; io.odin holds the routing. By pointer: a started Pool must not
    // move (work.odin), and an App is a value a test harness returns by copy.
    io:           ^work.Pool,
    io_jobs:      map[work.Id]Io_Job,
    // §10's recovery journal, per document: what is journaled is a descriptor read, not a
    // field, and journal.odin's header says why. By pointer, because the sink holds the
    // address across the document's whole life.
    journals:     map[store.Id]^Journal,
    // §13's quarantine: the plugins an earlier start died in, and the fd the fault handler
    // writes the next name to. Read before autoload, appended to by a handler that cannot open
    // a file of its own (quarantine.odin).
    quarantined:  [dynamic]string,
    report:       ^os.File,
    // Style-token names, interned (tokens.odin). A span carries an id; the palette says what
    // the id looks like, so a plugin never names a colour.
    tokens:       [dynamic]Token_Def,
    config:       Config, // config.conf, which holds one setting today (session.odin)
    cl:           Cmdline,
    chain:        Chain,
    job:          Job,
    sys_seq:      u64, // the last injection into N#; a report carrying another is stale
    binds:        [dynamic]input.Bind,
    reqs:         [dynamic]Bind_Request,
    clashes:      [dynamic]Bind_Clash,
    pending:      input.Pending,
    mouse:        input.Mouse_State,
    hover:        Hover,
    hand:         glfw.CursorHandle, // the pointer over a field a click would act on
    // Where each was drawn last frame. A click is placed against them, so the hit test reads
    // the layout the eye saw rather than recomputing one. Both in screen cells: the panel sits
    // at the screen's origin while there is one of it.
    body:         Rect, // the focused document
    bar:          Rect, // the command line's row, past the prompt
    message:      string, // owned; lives until the next keystroke
    home:         string, // owned; where binds.conf lives, empty in a test
    quit:         bool,
}

Rect :: struct {
    x, y, w, h: int,
}

// The field under the pointer that a bound click would act on (§8). Underlined, and no surface
// writes a line of it: the bind table is asked what a click there would do.
Hover :: struct {
    line, lo, hi: int,
    on:           bool,
}

app_init :: proc(a: ^App) {
    a.theme = gfx.DEFAULT_THEME
    a.hand = glfw.CreateStandardCursor(glfw.HAND_CURSOR)
    a.home = filepath.dir(os.args[0]) // beside the binary
    config_load(a)
    plug_init(a) // before binds_sync: a row may name a kind or a command a plugin registers
    cl_init(a)
    binds_sync(a)
}

app_destroy :: proc(a: ^App) {
    journals_destroy(a) // a clean exit leaves nothing to recover (§10)
    quarantine_destroy(a)
    job_destroy(a)
    io_destroy(a) // before the plugins: their close runs with no completion still arriving
    plug_destroy(a)
    tokens_destroy(a)
    chain_clear(a)
    cl_destroy(a)
    ring_destroy(a)
    terms_destroy(a)
    store.store_destroy(&a.docs)
    input.binds_destroy(&a.binds)
    binds_requests_destroy(a)
    message_set(a, "")
    delete(a.home)
    glfw.DestroyCursor(a.hand)
    gfx.grid_destroy(&a.panel)
    gfx.grid_destroy(&a.chrome)
    gfx.painter_destroy(&a.painter) // the atlas and its faces go with it
}

// Echo style: a message lives until the next keystroke clears it.
message_set :: proc(a: ^App, text: string) {
    delete(a.message)
    a.message = text == "" ? "" : strings.clone(text)
}

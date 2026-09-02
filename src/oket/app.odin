package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:glfw"
import "../gfx"
import "../input"
import "../store"

// The kernel's whole mutable state: one window, a store of documents, the ring that says which
// one is on screen, one bind table, and the command line.

App :: struct {
    window:       glfw.WindowHandle,
    painter:      gfx.Painter,
    grid:         gfx.Grid,
    theme:        gfx.Theme,
    docs:         store.Store,
    ring:         Ring,
    cl:           Cmdline,
    chain:        Chain,
    job:          Job,
    binds:        [dynamic]input.Bind,
    reqs:         [dynamic]Bind_Request,
    clashes:      [dynamic]Bind_Clash,
    pending:      input.Pending,
    mouse:        input.Mouse_State,
    hover:        Hover,
    hand:         glfw.CursorHandle, // the pointer over a field a click would act on
    // Where each was drawn last frame. A click is placed against them, so the hit test reads
    // the layout the eye saw rather than recomputing one.
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
    cl_init(a)
    binds_sync(a)
}

app_destroy :: proc(a: ^App) {
    job_destroy(a)
    chain_clear(a)
    cl_destroy(a)
    ring_destroy(a)
    store.store_destroy(&a.docs)
    input.binds_destroy(&a.binds)
    binds_requests_destroy(a)
    message_set(a, "")
    delete(a.home)
    glfw.DestroyCursor(a.hand)
    gfx.grid_destroy(&a.grid)
    gfx.painter_destroy(&a.painter) // the atlas and its faces go with it
}

// Echo style: a message lives until the next keystroke clears it.
message_set :: proc(a: ^App, text: string) {
    delete(a.message)
    a.message = text == "" ? "" : strings.clone(text)
}

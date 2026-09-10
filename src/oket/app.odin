package main

import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import "../gfx"
import "../input"
import "../store"
import "../strip"
import "../work"

// The kernel's whole mutable state: one window, a store of documents, the ring that says which
// one is on screen, one bind table, and the command line.

App :: struct {
    window:       ^sdl.Window,
    painter:      gfx.Painter,
    // Two lattices, not one (PANELS.md §7). The ground is the screen's, at whole cells: the
    // bar, and the ground a panel is drawn onto. A panel is a window onto a document and takes
    // an origin of its own, so it can slide without dragging the bar with it.
    ground:       gfx.Grid,
    // The strip (PANELS.md §2, §5). A default start is one panel at full width, which is a
    // strip of length one and not a special case; `focus` says which one the ring and the keys
    // act on. The layout itself is src/strip's: this is the camera and the two measurements it
    // works in, and the widths live on the panels.
    panels:       [dynamic]Panel,
    focus:        int,
    // The menubar's three grids and where the last draw put each (MENU.md §4). Painted AFTER
    // the panels: the ground is painted first and a panel covers it, so a bar drawn into the
    // ground would be invisible. `on` is what the frame DREW, so a box with no room to draw in
    // paints nothing.
    menu:         [Menu_Part]Menu_Layer,
    // Where the keys are while the menu is up (MENU.md §5), the state the pointer moves too.
    // The Pending_Menu in `pending` is still the one thing that says a menu IS up; this is only
    // meaningful then, and menu_open resets it.
    menu_nav:     Menu_Nav,
    strip:        strip.Strip,
    // The cell, in pixels, as the last fit measured it. The grids are cells and the strip is
    // pixels, so the conversion is written down once rather than asked of the painter from
    // every rectangle that needs it — a test has no painter and still has a strip.
    cell:         [2]int,
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
    // §5's trace file, beside it: the frames the handler walked before it unwound, so a
    // recovered fault names a line and not only a plugin (fault.odin).
    traces:       ^os.File,
    // Style-token names, interned (tokens.odin). A span carries an id; the palette says what
    // the id looks like, so a plugin never names a colour.
    tokens:       [dynamic]Token_Def,
    // The loaded theme (theme.odin): the file's scopes, and the name last applied so a sync is
    // a compare. Empty scopes is the baked palette.
    scopes:       map[string]Theme_Entry,
    theme_on:     string, // owned
    // Who publishes style runs, interned by name (spans.odin). The store keys its buckets by
    // the id; config ranks them by the name.
    producers:    [dynamic]string,
    config:       Config, // config.conf, which holds two settings today (config.odin)
    creqs:        [dynamic]Config_Request, // what a plugin asked the file for (§7)
    // What the two config files could not be read as (config.odin). The bar says the last one
    // and the next keystroke clears it; the home page lists them all, because a start is where
    // a typo in binds.conf is actually read.
    gripes:       [dynamic]Gripe,
    // How this start was asked to come up (§13). An escape hatch rather than a setting, and
    // the home page says which one is on: a start that holds every plugin back looks exactly
    // like a start whose plugins are broken.
    start:        Start_Mode,
    // §6's second oket: no window, no fault net, and a file of chain lines instead of a frame
    // loop (harness.odin). What it changes down here is where the kernel TALKS — a spawned
    // process's N0 is a PTY nobody can see, so `sys_print` goes to stdout instead.
    harness:      bool,
    // The view pipeline (VIEWS.md §5), per document: the text that is DRAWN, the map back to
    // the original, and the runs no cell stands for. Absent for every document until a
    // `[<kind>] view =` line names a stage. By pointer, because a derived text borrows the
    // blocks of the stage before it (views.odin).
    views:        map[store.Id]^Pipeline,
    view_rev:     u64, // bumped when a plugin or the config moves, which invalidates every chain
    cl:           Cmdline,
    chain:        Chain,
    // `:do`'s pending lines, each run as its own chain once the current one ends. On the App
    // and not the Chain, because a queued line's parse clears the chain and must not eat the
    // lines behind it (chain.odin).
    queue:        [dynamic]string,
    job:          Job,
    sys_seq:      u64, // the last injection into N0; a report carrying another is stale
    binds:        [dynamic]input.Bind,
    reqs:         [dynamic]Bind_Request,
    clashes:      [dynamic]Bind_Clash,
    pending:      input.Pending,
    // The key that is down, if one is (PANELS.md §6). It qualifies the next chord — `tab+enter`
    // is not `enter` — and its release is what commits an armed picker. One field, because a
    // chord holds one key and a release never reaches the bind table.
    held:         input.Code,
    mouse:        input.Mouse_State,
    hand:         ^sdl.Cursor, // the pointer over a field a click would act on
    preedit:      string, // owned; the platform IME's uncommitted text, "" outside composition
    ime_area:     sdl.Rect, // the caret rect last handed to SDL, so a still frame says nothing
    // Where the command line's row was drawn, past the prompt, in ground cells. A document's
    // own rectangle is its panel's (panel.odin), because a cell number counts from one grid.
    bar:          Rect,
    message:      string, // owned; lives until the next keystroke
    clips:        [dynamic]Clip, // owned; the kill ring, newest first
    // The face size the atlas is baked at, and the one the system asked for. `font.reset` goes
    // back to the second; a zoom step counts from the first.
    font_px:      int,
    font_system:  int,
    // Where you have been, and where you are standing in that list (jump.odin).
    jumps:        [dynamic]Jump,
    jump_at:      int,
    find:         string, // owned; the last search term, which is what F3 steps through
    paste:        Paste_Mark,
    // One directory per kind of file, chosen by where the binary is (path.odin). Empty in a
    // test that holds an App of its own, which is what every write site refuses on.
    home:         Home,
    // Where oket thinks it IS: the first directory on the command line, else the working
    // directory it started in. Every terminal is spawned here, so two panels holding two shells
    // cannot disagree about where they are.
    dir:          string, // owned
    quit:         bool,
}

// One field, not two flags: `--safe` is `--no-plugins` plus ignoring the session, so a
// safe-without-no-plugins state must not exist to hold.
Start_Mode :: enum {
    Ordinary,
    No_Plugins,
    Safe,
}

Rect :: struct {
    x, y, w, h: int,
}

// The three directories are an ARGUMENT because the harness runs on a scratch home (§6): a
// repro must not write the config file, the session or the journal of the oket that spawned it.
// Owned from here on, and freed by app_destroy.
app_init :: proc(a: ^App, home: Home) {
    a.theme = gfx.DEFAULT_THEME
    if a.window != nil {
        a.hand = sdl.CreateSystemCursor(.POINTER) // the window's, so a harness App makes none
    }
    a.home = home
    a.dir = start_dir(os.args[1:])
    // Read once, here, so main and the home page cannot disagree about which start this is.
    switch {
    case flag(SAFE):
        a.start = .Safe
    case flag(NO_PLUGINS):
        a.start = .No_Plugins
    }
    config_sync(a)
    plug_init(a) // before binds_sync: a row may name a kind or a command a plugin registers
    cl_init(a)
    binds_sync(a)
}

app_destroy :: proc(a: ^App) {
    journals_destroy(a) // a clean exit leaves nothing to recover (§10)
    quarantine_destroy(a)
    fault_trace_close(a)
    job_destroy(a)
    io_destroy(a) // before the plugins: their close runs with no completion still arriving
    plug_destroy(a)
    tokens_destroy(a)
    theme_destroy(a)
    producers_destroy(a)
    views_destroy(a)
    config_requests_destroy(a)
    config_destroy(&a.config)
    gripes_destroy(a)
    chain_clear(a)
    queue_destroy(a)
    cl_destroy(a)
    ring_destroy(a)
    terms_destroy(a)
    store.store_destroy(&a.docs)
    input.binds_destroy(&a.binds)
    binds_requests_destroy(a)
    input.pending_set(&a.pending) // an armed picker owns the line it captured
    message_set(a, "")
    clips_free(a) // the ring, not the selection: exiting must not empty the user's clipboard
    jumps_free(a)
    find_free(a)
    home_destroy(&a.home)
    delete(a.dir)
    delete(a.preedit)
    panels_destroy(a)
    menubar_destroy(a)
    gfx.grid_destroy(&a.ground)
    // The window's two: the cursor it set, and the atlas its GL context holds. A harness App has
    // neither, and freeing a texture into a context that is not there is a crash on the way out.
    if a.window != nil {
        sdl.DestroyCursor(a.hand)
        gfx.painter_destroy(&a.painter) // the atlas and its faces go with it
    }
}

// Echo style: a message lives until the next keystroke clears it.
message_set :: proc(a: ^App, text: string) {
    delete(a.message)
    a.message = text == "" ? "" : strings.clone(text)
}

package main

import "core:os"
import "core:time"
import "core:strings"
import sdl "vendor:sdl3"
import "../gfx"
import "../desc"
import "../input"
import "../plug"
import "../store"
import "../strip"
import "../cl"

// The kernel's whole mutable state: one window, a store of documents, the ring that says which
// one is on screen, one bind table, and the command line.
//
// An App is a HANDLE on it. Tests build one and return it by value, and lues's hooks reach the
// same state through k.user, so the state itself never moves.
App :: struct {
    using state: ^State,
}

State :: struct {
    window:       ^sdl.Window,
    painter:      gfx.Painter,
    // The bar's own one-row grid (§11), anchored to the window's bottom edge: the one thing the
    // kernel writes onto the window itself. A panel is a window onto a document and takes a
    // grid of its own, so it can slide without dragging the bar with it.
    bar_grid:     gfx.Grid,
    // Where the frame's last solve put every piece of it (frame.odin, CHROME.md §2.1). Read by
    // the draw, the paint and the hit test; computed by none of them.
    frame:        Frame,
    // The frame's pass (CHROME.md §6): the boxes AROUND a document, as pixels. The grids are
    // cells and these are pixels, two lattices on purpose (PANELS.md §7).
    mesher:       gfx.Mesher,
    // The strip (PANELS.md §2, §5). A default start is one panel at full width, which is a
    // strip of length one and not a special case; `focus` says which one the ring and the keys
    // act on. The layout itself is src/strip's: this is the camera and the two measurements it
    // works in, and the widths live on the panels.
    panels:       [dynamic]Panel,
    focus:        int,
    // The menubar's three grids and its nav (MENU.md §4, §5).
    menu:         Menu_Screen,
    strip:        strip.Strip,
    // The window and the cell, in pixels, as the last fit measured them. The grids are cells
    // and the strip is pixels, so the conversion is written down once rather than asked of the
    // painter from every rectangle that needs it — a test has no painter and still has a strip.
    win:          [2]int,
    cell:         [2]int,
    theme:        gfx.Theme,
    // lues (plug.odin), on the heap: it may not move once started. `docs` is its store.
    kernel:       ^Kernel,
    docs:         ^store.Store,
    ring:         Ring,
    // Every live PTY session, by the document it drives. A terminal is a kernel-implemented
    // document (§7), so what a session needs past text and a descriptor lives here and not in
    // the store.
    terms:        map[store.Id]^Term,
    // oket's own per-plugin state (plug.odin): view stages by plugin slot, and the descriptor
    // each plugin staged for its next submit to a doc.
    viewers:      map[int]plug.View_Fn,
    staged:       map[Staged]^desc.Descriptor,
    opens:        [dynamic]Plug_Open, // what plugins asked to open, done when their call returns
    // Transactions and caret sets landed since docs_settle last looked (hooks.drained).
    settled:      int,
    // §10's recovery journal, per document: what is journaled is a descriptor read, not a
    // field, and journal.odin's header says why. By pointer, because the sink holds the
    // address across the document's whole life.
    journals:     map[store.Id]^Journal,
    // What the palette says each interned token looks like, by id (tokens.odin).
    tokens:       [dynamic]Token_Def,
    // The loaded theme (theme.odin): the file's scopes, and the name last applied so a sync is
    // a compare. Empty scopes is the baked palette.
    scopes:       map[string]Theme_Entry,
    theme_on:     string, // owned
    config:       Config, // config.conf, which holds two settings today (config.odin)
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
    job:          Job,
    sys_seq:      u64, // the last injection into N0; a report carrying another is stale
    binds:        [dynamic]input.Bind,
    pending:      input.Pending,
    // The key that is down, if one is (PANELS.md §6). It qualifies the next chord — `tab+enter`
    // is not `enter` — and its release is what commits an armed picker. One field, because a
    // chord holds one key and a release never reaches the bind table.
    held:         input.Code,
    mouse:        input.Mouse_State,
    hand:         ^sdl.Cursor, // the pointer over a field a click would act on
    preedit:      string, // owned; the platform IME's uncommitted text, "" outside composition
    ime_area:     sdl.Rect, // the caret rect last handed to SDL, so a still frame says nothing
    // Where the command line's row was drawn, past the prompt, in the bar grid's cells. A
    // document's own rectangle is its panel's (panel.odin), because a cell number counts from
    // one grid.
    bar:          Cells,
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
    conf_seen:    [2]time.Time, // binds.conf and config.conf as last read (confs_fresh)
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

Cells :: struct {
    x, y, w, h: int,
}

// The state and its kernel. The three directories are an ARGUMENT because the harness runs on a
// scratch home (§6): a repro must not write the config file, the session or the journal of the
// oket that spawned it. Owned from here on, and freed by app_destroy. `unguarded` is the
// harness's: no fault net, so a plugin's crash is a crash.
app_make :: proc(home: Home = {}, unguarded := false) -> (a: App, ok: bool) {
    a.state = new(State)
    a.theme = gfx.DEFAULT_THEME
    a.home = home
    return a, kernel_open(&a, unguarded)
}

// Another home, for the App and the kernel that reads it (lues borrows the strings).
app_home :: proc(a: ^App, dir: string) {
    home_set(&a.home, dir)
    a.kernel.home = kernel_home(a.home)
}

app_init :: proc(a: ^App) {
    if a.window != nil {
        a.hand = sdl.CreateSystemCursor(.POINTER) // the window's, so a harness App makes none
    }
    a.dir = start_dir(os.args[1:])
    // Read once, here, so main and the home page cannot disagree about which start this is.
    switch {
    case flag(SAFE):
        a.start = .Safe
    case flag(NO_PLUGINS):
        a.start = .No_Plugins
    }
    config_sync(a)
    cl_init(a)
    binds_sync(a)
    a.conf_seen = confs_stamp(a)
}

// Whatever holds a document or a snapshot goes before the kernel, whose heap they are on.
app_destroy :: proc(a: ^App) {
    journals_destroy(a) // a clean exit leaves nothing to recover (§10)
    job_destroy(a)
    views_destroy(a)
    cl.destroy(&a.chain)
    cl_destroy(a)
    ring_destroy(a)
    terms_destroy(a)
    kernel_close(a)
    tokens_destroy(a)
    theme_destroy(a)
    config_destroy(&a.config)
    gripes_destroy(a)
    input.binds_destroy(&a.binds)
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
    gfx.grid_destroy(&a.bar_grid)
    // The window's two: the cursor it set, and the atlas its GL context holds. A harness App has
    // neither, and freeing a texture into a context that is not there is a crash on the way out.
    if a.window != nil {
        sdl.DestroyCursor(a.hand)
        gfx.mesher_destroy(&a.mesher)
        gfx.painter_destroy(&a.painter) // the atlas and its faces go with it
    }
    free(a.state)
    a.state = nil
}

// Echo style: a message lives until the next keystroke clears it.
message_set :: proc(a: ^App, text: string) {
    delete(a.message)
    a.message = text == "" ? "" : strings.clone(text)
}

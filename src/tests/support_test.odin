package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "../desc"
import "../gfx"
import "../input"
import "../store"
import "../txt"
import app "../oket"

// The App harness the end-to-end tests share: a kernel with a grid and a bind table and no
// window, which is what lets a click or a chain be driven from a test at all.

// A directory of its own per test: the runner is threaded, and two tests sharing one would each
// be reading the other's setup.
scratch :: proc(t: ^testing.T, name: string) -> (dir: string, ok: bool) {
    tmp, _ := os.temp_directory(context.temp_allocator)
    dir, _ = filepath.join({tmp, name}, context.temp_allocator)
    os.remove_all(dir)
    if err := os.make_directory(dir); err != nil {
        testing.expectf(t, false, "cannot make %s: %v", dir, err)
        return "", false
    }
    for entry in ([?]string{"alpha.txt", "beta.txt"}) {
        path, _ := filepath.join({dir, entry}, context.temp_allocator)
        if err := os.write_entire_file(path, transmute([]u8)string("xyz")); err != nil {
            testing.expectf(t, false, "cannot write %s: %v", path, err)
            return "", false
        }
    }
    return dir, true
}

// A kernel with nothing in the ring. `home` stays empty: syncing binds.conf would write beside
// the test binary, which races the parallel runner and is not this App's file to write.
bare_app :: proc(cols := 50, rows := 4) -> (a: app.App, ok: bool) {
    a.theme = gfx.DEFAULT_THEME
    a.binds = input.binds_default()
    if !gfx.grid_init(&a.grid, cols, rows) {
        return {}, false
    }
    a.body = {0, 0, cols, max(rows - 1, 0)}
    return a, true
}

// The same, with a listing of a fresh scratch directory focused and drawn once — the document
// that declares `fields` and selects by row, so it is what the mouse and the holes are tested
// against.
listing_app :: proc(t: ^testing.T, name: string) -> (a: app.App, dir: string, ok: bool) {
    dir = scratch(t, name) or_return
    a = bare_app() or_return
    app.ring_add(&a, app.listing_open(&a, dir))
    app.surface_draw(&a) // the body rectangle a click is placed against
    return a, dir, true
}

close_app :: proc(a: ^app.App) {
    app.job_destroy(a)
    app.io_destroy(a) // the worker thread, joined, the same way app_destroy ends one
    app.chain_clear(a)
    app.cl_destroy(a)
    app.ring_destroy(a)
    app.terms_destroy(a)
    store.store_destroy(&a.docs)
    input.binds_destroy(&a.binds)
    app.binds_requests_destroy(a)
    app.message_set(a, "")
    gfx.grid_destroy(&a.grid)
}

// A document with a file and text in it, and no owner behind it. The kernel has no `text` kind
// — a file in a buffer is the editor plugin's — so a test that only needs SOMETHING editable
// in the ring builds one here rather than compiling a plugin for it.
scratch_doc :: proc(a: ^app.App, file, text: string) -> store.Id {
    id := store.store_open(&a.docs, text)
    gen, _ := store.store_gen(&a.docs, id)
    d := desc.new_from(
        {
            numbers = .Absolute,
            ctx = .Text,
            file = file,
            selection = .Char,
            editable = true,
            tab_width = 4,
        },
    )
    store.store_submit(&a.docs, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&a.docs)
    return id
}

// --- the plugin harness ---

REPO :: #directory + "../../"

// A kernel with a home of its own and the named plugins built into it, by plugins/stage.sh —
// the same script release.sh runs and `:pluginify` writes a command line for, so what a test
// exercises is what ships. Each is a directory under the repo, because a fixture that nobody
// should ship does not live in plugins/. Built per test: the runner is threaded, and two tests
// sharing an output directory would each be loading the other's build.
@(require_results)
plug_app :: proc(t: ^testing.T, name: string, plugins: ..string) -> (a: app.App, ok: bool) {
    home := scratch(t, name) or_return
    out, _ := filepath.join({home, app.PLUGIN_DIR}, context.temp_allocator)
    script, _ := filepath.join({REPO, "plugins", "stage.sh"}, context.temp_allocator)
    wanted := plugins if len(plugins) > 0 else {"plugins/hello"}

    for plugin in wanted {
        src, _ := filepath.join({REPO, plugin}, context.temp_allocator)
        state, _, errs, err := os.process_exec(
            {command = {script, src, out}},
            context.temp_allocator,
        )
        if err != nil || !state.success {
            testing.expectf(t, false, "stage.sh %s: %v %s", plugin, err, string(errs))
            return {}, false
        }
    }
    a = bare_app() or_return
    a.home = strings.clone(home) // owned by the App, freed with it
    return a, true
}

close_plug_app :: proc(a: ^app.App) {
    app.plug_destroy(a)
    app.tokens_destroy(a) // a plugin interns style-token names, and they are the App's
    delete(a.home)
    a.home = ""
    close_app(a)
}

// A document's whole text, for a test that reads what a plugin wrote.
doc_text :: proc(a: ^app.App, id: store.Id) -> string {
    doc := store.store_doc(&a.docs, id)
    if doc == nil {
        return ""
    }
    last := txt.text_line_count(&doc.pt) - 1
    return txt.doc_text(doc, {0, 0}, {last, txt.text_line_len(&doc.pt, last)},
                        context.temp_allocator)
}

// The frame loop, as a test has one: pump §9's completions until `of` answers `want`. main.odin
// is woken by the worker and idles otherwise; a test polls because it has no window.
io_settle :: proc(a: ^app.App, of: proc(a: ^app.App) -> string, want: string, secs := 5) -> bool {
    for _ in 0 ..< secs * 200 {
        app.io_pump(a)
        if of(a) == want {
            return true
        }
        time.sleep(5 * time.Millisecond)
    }
    return false
}

echo_line :: proc(a: ^app.App) -> string {
    return a.message
}

focused_text :: proc(a: ^app.App) -> string {
    s := app.ring_focused(&a.ring)
    return s == nil ? "" : doc_text(a, s.doc)
}

read_binds :: proc(a: ^app.App) -> string {
    raw, _ := os.read_entire_file(app.binds_path(a), context.temp_allocator)
    return string(raw)
}

// The caret the frame renders, which lives in the viewport of whatever the keys are aimed at.
point :: proc(a: ^app.App) -> txt.Cursor {
    return app.active(a).view.point
}

chord :: proc(name: string, mods: input.Mods = {}) -> input.Chord {
    code, _ := input.key_code(name)
    return {code, mods}
}

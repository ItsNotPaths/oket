package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "../desc"
import "../gfx"
import "../input"
import "../store"
import "../txt"
import app "../oket"

// The App harness the end-to-end tests share: a kernel with the frame's two grids and a bind
// table and no window, which is what lets a click or a chain be driven from a test at all.

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
    a.binds = app.binds_base()
    if !gfx.grid_init(&a.chrome, cols, rows) {
        return {}, false
    }
    app.surface_fit(&a, cols, rows) // the strip, sized by the one rule that owns the split
    return a, true
}

// The strip is one panel long (PANELS.md §5), and its grid is where a document is drawn. Every
// snapshot below diffs that grid rather than the chrome, which carries only the bar.
panel_grid :: proc(a: ^app.App) -> ^gfx.Grid {
    return &app.panel_focused(a).grid
}

// The same, with a listing of a fresh scratch directory focused and drawn once — the document
// that declares `fields` and selects by row, so it is what the mouse and the holes are tested
// against.
listing_app :: proc(t: ^testing.T, name: string) -> (a: app.App, dir: string, ok: bool) {
    dir = scratch(t, name) or_return
    a = bare_app() or_return
    app.ring_add(&a, listing_doc(&a, dir))
    app.surface_draw(&a) // the body rectangle a click is placed against
    return a, dir, true
}

close_app :: proc(a: ^app.App) {
    app.journals_destroy(a) // a clean exit leaves nothing to recover, the same as app_destroy
    app.quarantine_destroy(a)
    app.job_destroy(a)
    app.io_destroy(a) // the worker thread, joined, the same way app_destroy ends one
    app.chain_clear(a)
    app.cl_destroy(a)
    app.ring_destroy(a)
    app.terms_destroy(a)
    store.store_destroy(&a.docs)
    input.binds_destroy(&a.binds)
    app.binds_requests_destroy(a)
    input.pending_set(&a.pending) // an armed picker owns its line, the same as app_destroy
    app.message_set(a, "")
    app.panels_destroy(a)
    gfx.grid_destroy(&a.chrome)
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

// --- a seeded generator ---

// The seed every property test starts from. One value, so a failure reproduces from the test
// name alone.
RNG_SEED :: 0x5EED

// Not core:math/rand: a failing step has to be reproducible from the seed, and that is only
// true if the sequence cannot move under the test. Answers 0 ..< n, and 0 when n is not
// positive.
rng_next :: proc(seed: ^u64, n: int) -> int {
    seed^ ~= seed^ << 13
    seed^ ~= seed^ >> 7
    seed^ ~= seed^ << 17
    return n > 0 ? int(seed^ % u64(n)) : 0
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
    s := app.ring_focused(a)
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

// `held` is the key that is DOWN when the chord fires, spelled the way a bind row spells it
// (PANELS.md §6). Empty for every chord that is not part of a gesture.
chord :: proc(name: string, mods: input.Mods = {}, held := "") -> input.Chord {
    code, _ := input.key_code(name)
    down, _ := input.key_code(held)
    return {code, mods, down}
}

// --- a listing, as a FIXTURE ---
//
// The kernel opens no listing of its own any more: a directory goes to whoever registers the
// `files` kind, exactly as a file goes to `edit`, and that is the browser plugin. What these
// tests need is not a browser — it is A DOCUMENT THAT DECLARES `fields` AND SELECTS BY ROW, to
// point a click, a hole or a wheel at. So the shape the kernel used to build lives here, where
// it is a stand-in and not a second implementation of anything.
//
// It carries `home`'s kind so it lands in a lane and answers `[home]` rows; nothing here is
// about which kind it is.
// What it SHOWS. `path` is not among them: a row acts on the whole path, which the `path`
// field carries as its VALUE over the same span the name is drawn in.
LISTING_COLUMNS :: [?]desc.Column{{"name", 28, .Left}, {"kind", 4, .Left}, {"size", 9, .Right}}

// One row per entry, tab-separated, with each column's span recorded as a field. The separator
// is arbitrary: the descriptor says where the fields are, so nothing downstream parses this
// text again.
listing_doc :: proc(a: ^app.App, dir: string) -> store.Id {
    s := &a.docs
    columns := LISTING_COLUMNS
    text := strings.builder_make(context.temp_allocator)
    fields := make([dynamic]desc.Field, context.temp_allocator)

    // A directory that will not read is still a listing, and it still says which one: the
    // descriptor goes on either way, or a failed read would hand back a document of no kind and
    // the lane it was opened in would lose it.
    infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
    if err != nil {
        strings.write_string(&text, fmt.tprintf("cannot read %s: %v", dir, err))
        infos = nil
    }
    slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

    for info, line in infos {
        if line > 0 {
            strings.write_rune(&text, '\n')
        }
        is_dir := info.type == .Directory
        full, _ := filepath.join({dir, info.name}, context.temp_allocator)
        size := is_dir ? "" : fmt.tprintf("%d", info.size)
        cells := [?]string{info.name, is_dir ? "dir" : "file", size}
        at := 0
        for cell, i in cells {
            if i > 0 {
                strings.write_rune(&text, '\t')
                at += 1
            }
            strings.write_string(&text, cell)
            append(&fields, desc.Field{line, columns[i].name, at, at + len(cell), ""})
            if i == 0 {
                // The row is a LINK: the same span the name is drawn in, acting on the whole
                // path it stands for (desc.Field). Two fields over one span, and the one that
                // is not drawn carries its value rather than hiding its bytes in a cell.
                append(&fields, desc.Field{line, "path", at, at + len(cell), full})
            }
            at += len(cell)
        }
    }

    id := store.store_open(s, strings.to_string(text))
    gen, _ := store.store_gen(s, id)
    // `surface`, not `text`: a listing's keys are a surface's, so `enter` here and `enter` in an
    // editor are two rows rather than one mode. Rows are what it selects, which is the drag
    // granularity as well (§5, §8). Not editable: a listing is not a text field.
    d := desc.new_from(
        {
            numbers = .Absolute,
            ctx = .Surface,
            kind = app.KIND_HOME,
            file = dir,
            selection = .Line,
            tab_width = 4,
            columns = columns[:],
            fields = fields[:],
        },
    )
    store.store_submit(s, id, gen, nil, d)
    desc.release(d)
    store.store_drain(s)
    return id
}

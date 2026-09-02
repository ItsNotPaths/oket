package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
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
    app.ring_add(&a, app.listing_open(&a.docs, dir))
    app.surface_draw(&a) // the body rectangle a click is placed against
    return a, dir, true
}

close_app :: proc(a: ^app.App) {
    app.job_destroy(a)
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

// The caret the frame renders, which lives in the viewport of whatever the keys are aimed at.
point :: proc(a: ^app.App) -> txt.Cursor {
    return app.active(a).view.point
}

chord :: proc(name: string, mods: input.Mods = {}) -> input.Chord {
    code, _ := input.key_code(name)
    return {code, mods}
}

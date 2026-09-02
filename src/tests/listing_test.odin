package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"
import app "../oket"

// The kernel's hardcoded surface (stage 3). What is asserted is that the listing's spans line
// up with its text, because a field whose bounds drift is a `<path>` that silently resolves to
// the wrong thing.

// A directory of its own per test: the runner is threaded, and two tests sharing one would
// each be reading the other's setup.
@(private = "file")
scratch :: proc(t: ^testing.T, name: string) -> (dir: string, ok: bool) {
    tmp, _ := os.temp_directory(context.temp_allocator)
    dir, _ = filepath.join({tmp, name}, context.temp_allocator)
    os.remove_all(dir)
    if err := os.make_directory(dir); err != nil {
        testing.expectf(t, false, "cannot make %s: %v", dir, err)
        return "", false
    }
    for name in ([?]string{"beta.txt", "alpha.txt"}) {
        path, _ := filepath.join({dir, name}, context.temp_allocator)
        if err := os.write_entire_file(path, transmute([]u8)string("xyz")); err != nil {
            testing.expectf(t, false, "cannot write %s: %v", path, err)
            return "", false
        }
    }
    return dir, true
}

@(test)
listing_fields_name_their_own_text :: proc(t: ^testing.T) {
    dir, ok := scratch(t, "oket-listing-fields")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    s: store.Store
    defer store.store_destroy(&s)
    id := app.listing_open(&s, dir)

    snap := store.store_snapshot(&s, id)
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&s, id)
    defer desc.release(d)

    testing.expect_value(t, txt.text_line_count(snap), 2)
    for want, line in ([?]string{"alpha.txt", "beta.txt"}) { // sorted, not directory order
        path, path_ok := view.field_text(&snap.text, d, line, "path")
        testing.expect(t, path_ok)
        testing.expect_value(t, path, want)

        kind, _ := view.field_text(&snap.text, d, line, "kind")
        testing.expect_value(t, kind, "file")
        size, _ := view.field_text(&snap.text, d, line, "size")
        testing.expect_value(t, size, "3")
    }
}

// The listing is drawn by the same renderer a file is, through its descriptor alone.
@(test)
listing_draws_through_the_descriptor :: proc(t: ^testing.T) {
    dir, ok := scratch(t, "oket-listing-draw")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    // The frame, not the renderer: the body and the bar together, which is what a click is
    // placed against.
    a: app.App
    defer store.store_destroy(&a.docs)
    defer gfx.grid_destroy(&a.grid)
    a.theme = gfx.DEFAULT_THEME
    testing.expect(t, gfx.grid_init(&a.grid, 50, 3))
    a.id = app.listing_open(&a.docs, dir)

    app.surface_draw(&a)
    snap := gfx.grid_snapshot(&a.grid)
    defer delete(snap)

    testing.expect_value(t, snap, `1 alpha.txt                    file         3
2 beta.txt                     file         3
esc quits, f1 describes a chord`)
}

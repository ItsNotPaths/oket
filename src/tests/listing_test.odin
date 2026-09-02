package tests

import "core:fmt"
import "core:os"
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

@(test)
listing_fields_name_their_own_text :: proc(t: ^testing.T) {
    dir, ok := scratch(t, "oket-listing-fields")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    a, app_ok := bare_app()
    if !app_ok {
        return
    }
    defer close_app(&a)
    id := app.listing_open(&a, dir)

    snap := store.store_snapshot(&a.docs, id)
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)

    testing.expect_value(t, txt.text_line_count(snap), 2)
    for want, line in ([?]string{"alpha.txt", "beta.txt"}) { // sorted, not directory order
        // The name is what the column shows; the path is the whole thing it is the tail of, and
        // it is what a bind hands on.
        shown, shown_ok := view.field_text(&snap.text, d, line, "name")
        testing.expect(t, shown_ok)
        testing.expect_value(t, shown, want)
        path, path_ok := view.field_text(&snap.text, d, line, "path")
        testing.expect(t, path_ok)
        testing.expect_value(t, path, fmt.tprintf("%s/%s", dir, want))

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
    app.ring_add(&a, app.listing_open(&a, dir))
    defer app.ring_destroy(&a)

    app.surface_draw(&a)
    snap := gfx.grid_snapshot(&a.grid)
    defer delete(snap)

    // The bar names where you are now that there is a ring to be somewhere in.
    testing.expect_value(t, snap, fmt.tprintf(`1 alpha.txt                    file         3
2 beta.txt                     file         3
files 1  %s`, dir))
}

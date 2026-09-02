package tests

import "core:testing"
import "../gfx"

// The gate for build order step 1: screen state is text, so it diffs without golden images.
@(test)
grid_snapshot_is_text :: proc(t: ^testing.T) {
    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 8, 3))
    defer gfx.grid_destroy(&g)

    gfx.grid_write(&g, 0, 0, "hello", {1, 1, 1}, {})
    gfx.grid_write(&g, 2, 2, "ok", {1, 1, 1}, {})

    snap := gfx.grid_snapshot(&g)
    defer delete(snap)
    testing.expect_value(t, snap, "hello\n\n  ok")
}

// Writing past the right edge clips, it does not wrap onto the next row and it does not write
// out of bounds.
@(test)
grid_write_clips :: proc(t: ^testing.T) {
    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 4, 2))
    defer gfx.grid_destroy(&g)

    end := gfx.grid_write(&g, 2, 0, "abcd", {1, 1, 1}, {})
    testing.expect_value(t, end, 4)
    snap := gfx.grid_snapshot(&g)
    defer delete(snap)
    testing.expect_value(t, snap, "  ab\n")
}

@(test)
grid_resize_clears :: proc(t: ^testing.T) {
    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 4, 1))
    defer gfx.grid_destroy(&g)

    gfx.grid_write(&g, 0, 0, "xy", {1, 1, 1}, {})
    testing.expect(t, gfx.grid_resize(&g, 6, 2))
    testing.expect_value(t, g.cols, 6)
    snap := gfx.grid_snapshot(&g)
    defer delete(snap)
    testing.expect_value(t, snap, "\n")
}

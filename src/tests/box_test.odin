package tests

import "core:c"
import "core:testing"
import "../gfx"

// CHROME.md §6's drawing vocabulary, asserted with no window and no GL context. box.odin only
// appends vertices, so what a look produces is a count and a colour rather than a look —
// the same trade the chrome tests already make against `grid_snapshot` (§12).

@(private = "file")
AT :: gfx.Box{0, 0, 20, 10}

@(private = "file")
flat :: proc(c: [3]f32) -> gfx.Look {
    rgba := gfx.Rgba{c.r, c.g, c.b, 1}
    return {fill = {rgba, rgba}}
}

@(private = "file")
mesh :: proc(at: gfx.Box, look: gfx.Look) -> ([dynamic]gfx.Chrome_Vertex, [dynamic]c.int) {
    verts := make([dynamic]gfx.Chrome_Vertex, context.temp_allocator)
    idx := make([dynamic]c.int, context.temp_allocator)
    gfx.box_mesh(&verts, &idx, at, look)
    return verts, idx
}

// A square box is a fan of four corners: one hub and one vertex a corner, four triangles. The
// radius is not a branch anywhere below — it is the same ring with more steps in it.
@(test)
a_square_box_is_four_corners :: proc(t: ^testing.T) {
    verts, idx := mesh(AT, flat({1, 0, 0}))
    testing.expect_value(t, len(verts), 5)
    testing.expect_value(t, len(idx), 12)
    // The ring closes on itself: the last triangle's far edge is the first ring vertex.
    testing.expect_value(t, idx[len(idx) - 1], c.int(1))
}

@(test)
a_radius_is_the_same_ring_with_more_steps :: proc(t: ^testing.T) {
    look := flat({1, 0, 0})
    look.radius = 4
    verts, idx := mesh(AT, look)
    testing.expect_value(t, len(verts), 17) // one hub, four steps a corner
    testing.expect_value(t, len(idx), 48)
}

// A bevel is a SECOND shape under the fill, not four edge quads: that is what survives a corner
// radius, and it is why the bevel and the fill can carry the same gradient.
@(test)
a_bevel_is_a_second_shape :: proc(t: ^testing.T) {
    look := flat({1, 0, 0})
    look.border = 1
    verts, _ := mesh(AT, look)
    testing.expect_value(t, len(verts), 10)
}

// A box thinner than its own bevel IS the bevel. A hairline is what that draws, and nothing
// below it has to test for a negative width.
@(test)
a_box_thinner_than_its_bevel_is_the_bevel :: proc(t: ^testing.T) {
    look := flat({1, 0, 0})
    look.border = 1
    verts, _ := mesh({0, 0, 1, 10}, look)
    testing.expect_value(t, len(verts), 5)
}

@(test)
a_box_with_no_room_draws_nothing :: proc(t: ^testing.T) {
    verts, idx := mesh({0, 0, 0, 10}, flat({1, 0, 0}))
    testing.expect_value(t, len(verts), 0)
    testing.expect_value(t, len(idx), 0)
}

// The gradient is lerped down the BOX and not down the ring, so a bevel and the fill it wraps
// agree about where their two ends are. Corner order is clockwise from the top-left.
@(test)
a_gradient_runs_down_the_box :: proc(t: ^testing.T) {
    look := gfx.Look {
        fill = {{1, 0, 0, 1}, {0, 0, 1, 1}}, // red at the top, blue at the bottom
    }
    verts, _ := mesh(AT, look)
    testing.expect_value(t, verts[1].r, u8(255)) // top-left
    testing.expect_value(t, verts[1].b, u8(0))
    testing.expect_value(t, verts[3].r, u8(0)) // bottom-right
    testing.expect_value(t, verts[3].b, u8(255))
    testing.expect_value(t, verts[0].r, u8(128)) // the hub, halfway down
}

// The chrome pass blends ONE against ONE_MINUS_SRC_ALPHA (§6), so a vertex carries its colour
// already multiplied. Getting this wrong is a halo nobody can see in a count.
@(test)
a_vertex_carries_its_alpha_multiplied_in :: proc(t: ^testing.T) {
    look := gfx.Look {
        fill = {{1, 1, 1, 0.5}, {1, 1, 1, 0.5}},
    }
    verts, _ := mesh(AT, look)
    testing.expect_value(t, verts[1].r, u8(128))
    testing.expect_value(t, verts[1].a, u8(128))
}

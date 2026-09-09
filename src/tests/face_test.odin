package tests

import "core:testing"
import "../font"
import "../gfx"

// The system's own primary face at a fixed size; skips on a machine with no fonts.
@(private = "file")
open_primary :: proc(px: int) -> (gfx.Face, bool) {
    f, ok := font.system_fixed()
    if !ok {
        return {}, false
    }
    defer delete(f.family);defer delete(f.path)
    return gfx.face_open(f.path, px)
}

@(private = "file")
cell_ink :: proc(a: ^gfx.Atlas, slot: u16) -> int {
    ox, oy := gfx.atlas_origin(a, slot)
    w := gfx.atlas_width(a)
    n := 0
    for y in 0 ..< a.cell_h {
        for x in 0 ..< a.cell_w {
            if a.pixels[(oy + y) * w + ox + x] > 0 {
                n += 1
            }
        }
    }
    return n
}

// The primary face dictates the cell. If it did not, columns would stop being arithmetic.
@(test)
face_sets_the_cell :: proc(t: ^testing.T) {
    f, ok := open_primary(32)
    if !ok {
        return
    }
    w, h, baseline := gfx.face_cell(&f)
    defer gfx.face_close(&f)

    testing.expect(t, w > 0 && h > 0, "the face reports an empty cell")
    testing.expect(t, baseline > 0 && baseline <= h, "the baseline is outside the cell")
    // Asked for 32px: the row should be near that, and nowhere near the bitmap's 16.
    testing.expectf(t, h >= 28 && h <= 48, "a 32px face produced a %d-row cell", h)
}

// The whole lazy path: a rune the face has gets baked on demand, into a slot of its own, with
// ink in it.
@(test)
atlas_bakes_from_the_face :: proc(t: ^testing.T) {
    f, ok := open_primary(24)
    if !ok {
        return
    }
    faces := make([]gfx.Face, 1)
    faces[0] = f
    a, made := gfx.atlas_make(faces)
    testing.expect(t, made)
    defer gfx.atlas_destroy(&a)

    testing.expect(t, !gfx.atlas_is_fallback(&a))
    testing.expect(t, a.cell_h > 16, "the cell came from the bitmap, not the face")

    before := a.next
    slot := gfx.atlas_ensure(&a, 'A')
    testing.expect(t, slot != 0, "'A' baked as tofu")
    testing.expect(t, slot >= before, "'A' came from the floor rather than the face")
    testing.expect(t, cell_ink(&a, slot) > 0, "the baked cell is blank")
    testing.expect(t, len(a.dirty) > 0, "a freshly baked slot was not marked for upload")

    // Asking twice bakes once.
    n := a.next
    testing.expect_value(t, gfx.atlas_ensure(&a, 'A'), slot)
    testing.expect_value(t, a.next, n)
}

// A rune no face has still draws: the bundled bitmap is behind the stack, and the tofu behind
// that. Box drawing is the case that matters, since the UI is made of it.
@(test)
atlas_falls_through_to_the_floor :: proc(t: ^testing.T) {
    f, ok := open_primary(24)
    if !ok {
        return
    }
    faces := make([]gfx.Face, 1)
    faces[0] = f
    a, made := gfx.atlas_make(faces)
    testing.expect(t, made)
    defer gfx.atlas_destroy(&a)

    // Whoever ends up serving it, a box-drawing rune has to have ink.
    slot := gfx.atlas_ensure(&a, '─')
    testing.expect(t, slot != 0, "box drawing resolved to tofu")
    testing.expect(t, cell_ink(&a, slot) > 0, "box drawing baked blank")

    // Something no font on earth has: tofu, and it is drawn, not blank.
    tofu := gfx.atlas_ensure(&a, rune(0x10FFFD)) // a private-use plane 16 codepoint
    testing.expect_value(t, tofu, u16(0))
    testing.expect(t, cell_ink(&a, 0) > 0, "the tofu glyph is blank")
}

// The atlas keys on (face, glyph id), not the codepoint. So the shaped path — which knows the
// face and the id and never walks the stack — lands in the SAME cache the per-rune walk fills,
// and two glyphs of one face cannot collide (IME.md §6).
@(test)
the_atlas_keys_on_a_face_and_a_glyph :: proc(t: ^testing.T) {
    f, ok := open_primary(24)
    if !ok {
        return
    }
    id_a, id_b := gfx.face_glyph(&f, 'A'), gfx.face_glyph(&f, 'B')
    faces := make([]gfx.Face, 1)
    faces[0] = f
    a, made := gfx.atlas_make(faces)
    testing.expect(t, made)
    defer gfx.atlas_destroy(&a)

    testing.expect(t, id_a != 0 && id_b != 0 && id_a != id_b, "the face has no A and B")

    slot := gfx.atlas_ensure(&a, 'A')
    n := a.next
    same, baked := gfx.atlas_ensure_glyph(&a, gfx.Glyph{0, id_a})
    testing.expect(t, baked)
    testing.expect_value(t, same, slot) // the walk got there first; the key found its work
    testing.expect_value(t, a.next, n)

    other, _ := gfx.atlas_ensure_glyph(&a, gfx.Glyph{0, id_b})
    testing.expect(t, other != slot, "two glyphs of one face shared a slot")

    // A face the stack does not have bakes nothing rather than reading off the end.
    _, off_stack := gfx.atlas_ensure_glyph(&a, gfx.Glyph{7, id_a})
    testing.expect(t, !off_stack)
}

// A resize re-bakes every glyph at the new cell, so every cached answer about a rune is stale
// with it. Miss this and a zoom keeps drawing the old size out of slots that moved.
@(test)
a_resize_drops_what_the_face_walk_cached :: proc(t: ^testing.T) {
    f, ok := open_primary(16)
    if !ok {
        return
    }
    faces := make([]gfx.Face, 1)
    faces[0] = f
    a, made := gfx.atlas_make(faces)
    testing.expect(t, made)
    defer gfx.atlas_destroy(&a)

    gfx.atlas_ensure(&a, 'A')
    was_cell := a.cell_h

    testing.expect(t, gfx.atlas_resize(&a, 32))
    testing.expect(t, a.cell_h > was_cell, "the cell did not grow")

    n := a.next
    slot := gfx.atlas_ensure(&a, 'A')
    testing.expect(t, a.next > n, "'A' came back from the cache instead of re-baking")
    testing.expect(t, cell_ink(&a, slot) > 0, "the re-baked cell is blank")
}

package tests

import "core:strings"
import "core:testing"
import "../gfx"

// Renders one slot's coverage back to text. Pixels diff as text for the same reason screens do.
@(private = "file")
glyph_art :: proc(a: ^gfx.Atlas, r: rune, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    ox, oy := gfx.atlas_origin(a, gfx.atlas_slot(a, r))
    w := gfx.atlas_width(a)
    for y in 0 ..< a.cell_h {
        if y > 0 {
            strings.write_rune(&b, '\n')
        }
        for x in 0 ..< a.cell_w {
            strings.write_rune(&b, a.pixels[(oy + y) * w + ox + x] > 127 ? '#' : '.')
        }
    }
    return strings.to_string(b)
}

@(test)
fallback_atlas_loads :: proc(t: ^testing.T) {
    a, ok := gfx.atlas_fallback()
    testing.expect(t, ok, "the committed fallback blob failed to parse")
    defer gfx.atlas_destroy(&a)

    testing.expect_value(t, a.cell_w, 8)
    testing.expect_value(t, a.cell_h, 16)
    testing.expect(t, gfx.atlas_is_fallback(&a))
    // ASCII + Latin-1 + box drawing + blocks.
    // The floor: every bundled glyph, resident from startup.
    testing.expect_value(t, len(a.floor), 95 + 96 + 128 + 32)
}

// The whole unpack path in one assertion: header, range table, slot arithmetic and the 1-bit
// to 8-bit expansion all have to be right for this to match.
@(test)
fallback_atlas_unpacks_a_glyph :: proc(t: ^testing.T) {
    a, ok := gfx.atlas_fallback()
    testing.expect(t, ok)
    defer gfx.atlas_destroy(&a)

    art := glyph_art(&a, 'A')
    defer delete(art)
    testing.expect_value(
        t,
        art,
        `........
........
.#####..
##...##.
##...##.
##...##.
#######.
##...##.
##...##.
##...##.
##...##.
##...##.
........
........
........
........`,
    )
}

@(test)
fallback_atlas_has_box_drawing :: proc(t: ^testing.T) {
    a, ok := gfx.atlas_fallback()
    testing.expect(t, ok)
    defer gfx.atlas_destroy(&a)

    // U+2500 BOX DRAWINGS LIGHT HORIZONTAL: one solid row, nothing else.
    art := glyph_art(&a, '─')
    defer delete(art)
    testing.expect_value(t, strings.count(art, "########"), 1)
}

// A rune the atlas does not have draws the tofu box, never a blank. A blank would read as a
// space and hide the miss.
@(test)
fallback_atlas_misses_draw_tofu :: proc(t: ^testing.T) {
    a, ok := gfx.atlas_fallback()
    testing.expect(t, ok)
    defer gfx.atlas_destroy(&a)

    testing.expect_value(t, gfx.atlas_slot(&a, '一'), 0) // CJK, not in the fallback
    art := glyph_art(&a, '一')
    defer delete(art)
    testing.expect(t, strings.contains(art, "#"), "the tofu glyph is blank")
    testing.expect(t, gfx.atlas_slot(&a, 'A') != 0)
}

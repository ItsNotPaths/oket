package tests

import "core:testing"
import "../gfx"

// Width decides how many columns a rune eats, so a wrong answer shifts the rest of the line.
// The zero-width cases are the ones a hand-written table gets wrong.
@(test)
rune_width_is_right :: proc(t: ^testing.T) {
    cases := [?]struct {
        r:    rune,
        want: int,
        name: string,
    } {
        {0x0000, 0, "NUL"},
        {'A', 1, "latin"},
        {'é', 1, "precomposed latin-1"},
        {'─', 1, "box drawing"},
        {0x0301, 0, "combining acute"},
        {0x0E31, 0, "thai vowel sign"},
        {0x200B, 0, "zero-width space"},
        {0xFE0F, 0, "variation selector-16"},
        {0x1160, 0, "hangul jamo medial"},
        {0x00AD, 1, "soft hyphen (Cf, but drawn)"},
        {0x4E00, 2, "CJK ideograph"},
        {0xFF21, 2, "fullwidth A"},
        {0x3042, 2, "hiragana"},
        {0xAC00, 2, "hangul syllable"},
        {0x1F600, 2, "emoji"},
        {0x2E80, 2, "CJK radical"},
    }
    for c in cases {
        testing.expectf(t, gfx.rune_width(c.r) == c.want, "U+%04X %s: want %d, got %d",
                        c.r, c.name, c.want, gfx.rune_width(c.r))
    }
}

// The tables have to stay sorted and non-overlapping or the binary search silently misses.
@(test)
width_tables_are_sorted :: proc(t: ^testing.T) {
    check :: proc(t: ^testing.T, rs: [][2]rune, name: string) {
        for r, i in rs {
            testing.expectf(t, r[0] <= r[1], "%s[%d] is inverted", name, i)
            if i > 0 {
                testing.expectf(t, rs[i - 1][1] < r[0], "%s[%d] overlaps its predecessor", name, i)
            }
        }
    }
    check(t, gfx.WIDTH_ZERO[:], "WIDTH_ZERO")
    check(t, gfx.WIDTH_WIDE[:], "WIDTH_WIDE")

    // Nothing may be both zero-width and wide.
    for r in gfx.WIDTH_ZERO {
        testing.expect(t, gfx.rune_width(r[0]) == 0)
    }
}

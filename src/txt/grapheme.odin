package txt

import "core:unicode/utf8"
import "../uni"

// libgrapheme (vendored; IME.md §3): the one cluster-break authority. The helpers include the
// same library in C, so the kernel and every plugin read the SAME tables and the no-drift rule
// costs no generator. The API is forward-only, so every leftward question restarts from the
// line start and walks right — a line is short and this runs per keystroke, not per frame.
foreign import grapheme "../../vendor/libgrapheme/libgrapheme.a"

@(default_calling_convention = "c")
@(private = "file")
foreign grapheme {
    grapheme_next_character_break_utf8 :: proc(str: [^]u8, len: uint) -> uint ---
}

// The next cluster boundary after `off`; at least one byte while any remain, so a walk ends.
cluster_next :: proc(src: []u8, off: int) -> int {
    if off >= len(src) {
        return len(src)
    }
    rest := src[off:]
    step := int(grapheme_next_character_break_utf8(raw_data(rest), uint(len(rest))))
    return off + max(step, 1)
}

// The boundary strictly before `off` — the step-left answer, and the snap for a column that
// landed mid-cluster.
cluster_prev :: proc(src: []u8, off: int) -> int {
    i, prev := 0, 0
    for i < off && i < len(src) {
        prev = i
        i = cluster_next(src, i)
    }
    return prev
}

// The COLUMNS the cluster at `off` owns: its base rune's, because a cluster is one character
// however many codepoints spell it (IME.md §4). A conjunct owns one column, a wide base owns
// two, and the marks riding on either own none of their own. Callers handle the tab, which is
// the one width that depends on where it starts.
cluster_cells :: proc(src: []u8, off: int) -> int {
    if off >= len(src) {
        return 0
    }
    r, _ := utf8.decode_rune(src[off:])
    return uni.rune_width(r)
}

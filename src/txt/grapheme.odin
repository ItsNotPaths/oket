package txt

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

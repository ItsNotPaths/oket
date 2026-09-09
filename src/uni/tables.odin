package uni

// The generated Unicode tables and the lookups over them. `gfx` and `txt` are peers — the draw
// lays out a column and the document counts one — so the tables they must agree about live
// below them both. One binary search, not one per caller (IME.md §3).

// Cells a rune occupies: 0 for combining marks, 2 for East Asian wide, 1 for everything else.
// Below U+0300 everything is one column, so nearly all editor content skips the searches.
// ~1 ns a call either way.
rune_width :: proc(r: rune) -> int {
    if r < 0x0300 {
        return r == 0 ? 0 : 1
    }
    if in_ranges(WIDTH_ZERO[:], r) {
        return 0
    }
    if in_ranges(WIDTH_WIDE[:], r) {
        return 2
    }
    return 1
}

in_ranges :: proc(rs: [][2]rune, r: rune) -> bool {
    lo, hi := 0, len(rs) - 1
    for lo <= hi {
        mid := (lo + hi) / 2
        switch {
        case r < rs[mid][0]:
            hi = mid - 1
        case r > rs[mid][1]:
            lo = mid + 1
        case:
            return true
        }
    }
    return false
}

// --- scripts ---

// The four-byte ISO 15924 codes the run splitter treats as "whatever the run already is".
// Common is punctuation, digits and spaces; Inherited is what a combining mark takes from
// the character it sits on. Neither can start a run or break one.
SCRIPT_COMMON :: u32(0x5A797979) // Zyyy
SCRIPT_INHERITED :: u32(0x5A696E68) // Zinh
SCRIPT_UNKNOWN :: u32(0x5A7A7A7A) // Zzzz
SCRIPT_LATIN :: u32(0x4C61746E) // Latn

// A codepoint's script, as hb_script_t (IME.md §3, §5).
script_of :: proc(r: rune) -> u32 {
    lo, hi := 0, len(SCRIPT_RANGES) - 1
    for lo <= hi {
        mid := (lo + hi) / 2
        switch {
        case r < SCRIPT_RANGES[mid].lo:
            hi = mid - 1
        case r > SCRIPT_RANGES[mid].hi:
            lo = mid + 1
        case:
            return SCRIPT_RANGES[mid].iso
        }
    }
    return SCRIPT_UNKNOWN
}

// The script a run carries once `r` joins it. Common and Inherited never start one, so a
// quoted Arabic phrase is one Arabic run and not three, and a mark keeps its base's script.
script_join :: proc(run, r: u32) -> u32 {
    if r == SCRIPT_COMMON || r == SCRIPT_INHERITED || r == SCRIPT_UNKNOWN {
        return run
    }
    return run == SCRIPT_UNKNOWN ? r : run
}

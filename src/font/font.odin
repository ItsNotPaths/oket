package font

import "core:os"
import tt "vendor:stb/truetype"

// Finding the font the user actually wants. Runs from the config pane's "grab" button and on
// a first run, never at startup: the config is the only source of truth, and what this makes
// is written back as text the user can read and edit.
//
// A STACK, not a font: a plain face beside a symbols-only one is as common as a patched face
// carrying its own icons, and the patched case is just a stack of length one.

Found :: struct {
    family: string,
    path:   string,
    size:   f32, // points; 0 when the platform does not say
}

// Why an entry is in the stack; written into the config beside it.
Reason :: enum {
    Primary,
    Icons,
    CJK,
}

Entry :: struct {
    using found: Found,
    reason:      Reason,
}

// One representative codepoint per probe; a face carrying powerline effectively always
// carries the rest of the Nerd Font blocks.
ICON_PROBE :: '' // powerline right arrow
CJK_PROBE :: '一' // CJK unified ideograph 'one'

// Does this face have glyphs for all of these? stbtt reads the font's own cmap, so this is
// one implementation everywhere: finding candidates differs per OS, judging them does not.
covers :: proc(path: string, runes: ..rune) -> bool {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil || len(data) == 0 {
        return false
    }
    info: tt.fontinfo
    // Index 0 of a collection. Noto's CJK faces ship as .ttc, so this is not hypothetical.
    offset := tt.GetFontOffsetForIndex(raw_data(data), 0)
    if offset < 0 || !tt.InitFont(&info, raw_data(data), offset) {
        return false
    }
    for r in runes {
        if tt.FindGlyphIndex(&info, r) == 0 {
            return false
        }
    }
    return true
}

// The primary face plus whatever covers the icons and CJK it is missing. `family` empty
// means "ask the system"; naming one asks what that choice of primary would need beside it.
grab :: proc(family := "", allocator := context.allocator) -> (stack: []Entry, ok: bool) {
    primary := family == "" ? system_fixed(allocator) or_return : resolve(family, allocator) or_return
    out := make([dynamic]Entry, allocator)
    append(&out, Entry{primary, .Primary})

    if !covers(primary.path, ICON_PROBE) {
        if f, found := find_covering(ICON_PROBE, allocator); found {
            append(&out, Entry{f, .Icons})
        }
    }
    if !covers(primary.path, CJK_PROBE) {
        if f, found := find_covering(CJK_PROBE, allocator); found {
            append(&out, Entry{f, .CJK})
        }
    }
    return out[:], true
}

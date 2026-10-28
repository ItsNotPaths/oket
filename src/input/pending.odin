package input


// One pending state, never a pile of bools (§6). Whatever qualifies the next keystroke lives
// here; nil means keys mean what they always mean.
//
// Adding a variant forces a label into pending_describe, and the bar renders that label
// whenever the state is set. A state that is not shown cannot exist.

Pending_Describe :: struct {}

// The command line is open: modal until Enter or Escape. The bar row draws the line itself,
// which is the label a text-only describe cannot give.
Pending_Cmdline :: struct {}

// Alt held: a display state, not a capture — chords dispatch normally while the switcher
// overlay shows the ring. `alts` is which alt keys are down: with both held, one release must
// not take the column out from under the other.
Switcher_Alt :: enum u8 {
    Left,
    Right,
}

Pending_Switcher :: struct {
    alts: bit_set[Switcher_Alt],
}

// A primer is up (§4): the next chord is qualified by `chord`. The label is built at arm time —
// the table cannot change while a primer is up — and owned, so pending_set frees it.
// It points at the help chord and lists nothing: the MENUBAR holds the children, one row each,
// and a bar row that also listed them would be a second answer to one question (MENU.md §5).
Pending_Prefix :: struct {
    chord: Chord,
    label: string,
}

// The menubar is up (MENU.md §5): this state in the union is the one thing that says so. Where
// the keys are — the nav — lives on the App beside the menu grids, reset at the open, so this
// package needs no view of the menu. `prefix` is the primer whose popout it opened on, zero for
// a plain open: a chord the menu does not claim is still under that primer, so the fall-through
// has to resolve there rather than as itself.
Pending_Menu :: struct {
    prefix: Chord,
}

Pending :: union {
    Pending_Describe,
    Pending_Cmdline,
    Pending_Switcher,
    Pending_Prefix,
    Pending_Menu,
}

pending_describe :: proc(p: Pending) -> string {
    switch v in p {
    case Pending_Describe:
        return "describe: press any chord (esc cancels)"
    case Pending_Cmdline:
        return "command line: enter runs, esc closes"
    case Pending_Switcher:
        return "alt: 1-9 goes to a slot, 0 to N0, ` alternates, q closes"
    case Pending_Prefix:
        return v.label
    case Pending_Menu:
        return "menu: arrows choose, enter runs, esc closes; anything else falls through"
    }
    return ""
}

// The one door onto the field, because a state may own memory: a primer holds its label, and
// whatever replaces it — Escape, another capture, the exit — is what frees it.
pending_set :: proc(p: ^Pending, to: Pending = nil) {
    #partial switch it in p {
    case Pending_Prefix:
        delete(it.label)
    }
    p^ = to
}

package input

import "core:fmt"

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
// overlay shows the ring. `since` lets the overlay wait out a quick chord.
Pending_Switcher :: struct {
    since: f64,
}

// The picker is ARMED (PANELS.md §6): the line is already expanded and waiting, `chord` is the
// one whose release runs it, and `target` is the panel the side arrows have steered to. The
// state does not exist until a `pick` row arms it, so there is no flag to be false.
Pending_Pick :: struct {
    // The whole chord, not just its held key: its release commits the gesture and a REPEAT of
    // it is the key never having come up, which is not a second press of a row.
    chord:  Chord,
    // Owned, and expanded at the PRESS, so its holes read the point the chord fired on.
    line:   string,
    target: int,
}

Pending :: union {
    Pending_Describe,
    Pending_Cmdline,
    Pending_Switcher,
    Pending_Pick,
}

pending_describe :: proc(p: Pending) -> string {
    switch v in p {
    case Pending_Describe:
        return "describe: press any chord (esc cancels)"
    case Pending_Cmdline:
        return "command line: enter runs, esc closes"
    case Pending_Switcher:
        return "alt: 1-9 goes to a slot, 0 the system session, ` alternates, q closes"
    case Pending_Pick:
        return fmt.tprintf(
            "pick: @%d; arrows choose, the chord again makes a panel, release opens, esc cancels",
            v.target + 1,
        )
    }
    return ""
}

// The one door onto the field, because a state may own memory: an armed pick holds the line it
// captured, and whatever replaces it — Escape, another capture, the exit — is what frees it.
pending_set :: proc(p: ^Pending, to: Pending = nil) {
    if it, armed := p.(Pending_Pick); armed {
        delete(it.line)
    }
    p^ = to
}

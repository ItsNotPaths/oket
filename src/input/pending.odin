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
// overlay shows the ring. `since` lets the overlay wait out a quick chord.
Pending_Switcher :: struct {
    since: f64,
}

Pending :: union {
    Pending_Describe,
    Pending_Cmdline,
    Pending_Switcher,
}

pending_describe :: proc(p: Pending) -> string {
    switch _ in p {
    case Pending_Describe:
        return "describe: press any chord (esc cancels)"
    case Pending_Cmdline:
        return "command line: enter runs, esc closes"
    case Pending_Switcher:
        return "alt: 1-9 goes to a slot, 0 the system session, ` alternates, q closes"
    }
    return ""
}

// Escape's whole meaning while anything is pending: a field you clear, not an unwind.
pending_cancel :: proc(p: ^Pending) {
    p^ = nil
}

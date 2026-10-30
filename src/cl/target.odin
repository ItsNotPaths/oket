package cl

import "core:strconv"
import "core:strings"

// Addressing (PANELS.md §4). One grammar, and every builtin that takes a target parses it here.
//
//   #N    ring slot N, in the lane the document's kind belongs to
//   @N    panel N, counted from the left of the strip
//   @+N   N panels right of the focused one, @-N N left
//   N     an alias for #N, because that is what `:open <path> 3` meant before there were panels
//   @=    the panel already showing it, and the one you are in when no panel is
//   @*    every panel, #* every live slot of the lane — for verbs that ACT (`:width`, `:close`)
//
// The two sigils are §3's two axes and a line may carry one of each: `#N` says which slot holds
// the document, `@N` says which panel stands on it. Neither renumbers the other.
//
// `@=` is the only address whose answer depends on WHAT IS BEING OPENED rather than on the
// strip alone, which is why the reach takes a document. It is the automatic half of the
// routing, and it is opt-in per row: a line without it lands where you are, so `enter` still
// replaces the panel you are in and only a row that asks goes looking.
//
// `@N` IS NOT A SLOT NUMBER and never resolves to one here. Aim a panel holding a terminal at a
// file and that panel has to start pointing at an edit slot, possibly one that does not exist
// yet; which slot it lands in stays the kernel's business, the way `kind_fresh` is.

// The form the `@` took. The zero value is a line with no `@` at all.
Panel_Addr :: enum {
    Here,    // land in the panel the keys are already aimed at
    Nth,     // `@N`: panel N, counted from the left
    Step,    // `@±N`: N panels from the focused one
    Showing, // `@=`: the panel this document is already in
    All,     // `@*`: every panel on the strip — for a verb that ACTS, never for an open
}

Target :: struct {
    slot:  int, // `#N`. 0: wherever the document's own lane has room for it
    panel: int, // the N of `@N` or `@±N`; unread otherwise
    how:   Panel_Addr,
    slots: bool, // `#*`: every live slot of the focused lane; `slot` is unread
}

// The arguments past the one a builtin takes for itself, in any order, and the last of a sigil
// wins: a staged line you appended `#2` to means `#2`. A field that is not an address comes
// back in `bad`, because a mistyped target must report rather than open somewhere else.
target_parse :: proc(args: string) -> (t: Target, bad: string, ok: bool) {
    rest := strings.trim_space(args)
    for rest != "" {
        field := first_field(rest)
        rest = strings.trim_space(rest[len(field):])
        body := field
        panel := field[0] == '@'
        if panel || field[0] == '#' {
            body = field[1:]
        }
        // The two addresses that are not numbers. Written before the parse rather than as
        // cases inside it, because there is no integer either could stand for. `*` is a SET,
        // by exact form and never by pattern: a selector that wants matching goes through the
        // shell (`:get panels | grep ... | :do`), which already has one.
        if panel && body == "=" {
            t.panel, t.how = 0, .Showing
            continue
        }
        if body == "*" && field != body { // a bare `*` aliases nothing
            if panel {
                t.panel, t.how = 0, .All
            } else {
                t.slot, t.slots = 0, true
            }
            continue
        }
        n, num := strconv.parse_int(body, 10)
        step := body != "" && (body[0] == '+' || body[0] == '-')
        // A step is only a step toward a panel, and no address is zero: `@+0` is the panel you
        // are on, which is what naming no panel already means.
        if !num || n == 0 || (step && !panel) {
            return {}, field, false
        }
        if panel {
            t.panel, t.how = n, step ? Panel_Addr.Step : .Nth
        } else {
            t.slot, t.slots = n, false
        }
    }
    return t, "", true
}

// The pane index `.Here`, `.Nth` or `.Step` names on a strip of `count` with `focus` focused,
// and whether the strip has it. `.Showing` and `.All` are not one pane.
target_index :: proc(t: Target, focus, count: int) -> (int, bool) {
    #partial switch t.how {
    case .Here:
        return focus, true
    case .Nth:
        return t.panel - 1, t.panel <= count
    case .Step:
        i := focus + t.panel
        return i, i >= 0 && i < count
    }
    return focus, false
}

package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../store"

// Addressing (PANELS.md §4). One grammar, and every builtin that takes a target parses it here.
//
//   #N    ring slot N, in the lane the document's kind belongs to
//   @N    panel N, counted from the left of the strip
//   @+N   N panels right of the focused one, @-N N left
//   N     an alias for #N, because that is what `:open <path> 3` meant before there were panels
//   @=    the panel already showing it, and the one you are in when no panel is
//   @     the panel the picker was steered to, which only a gesture can name (§6)
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

// The panel a target names, made when the strip does not have it. That is the ring's own rule —
// `ring_put` grows a lane to reach the slot you asked for — and it reads as two here because a
// panel can be named two ways.
//
// `@N` counts from the left, so the strip is extended until there is an Nth panel. `@±N` is a
// WALK from the focused one, and a walk stops at the end it walks into: the panel it makes is
// the one at that end, which is also the only way to say "left of the leftmost". `@=` makes
// none: a panel showing the document either exists or it does not.
target_reach :: proc(a: ^App, t: Target, doc: store.Id) -> int {
    panels_ready(a)
    switch t.how {
    case .Here:
    case .Showing:
        // A document already up goes to the panel that has it and the rest of the strip is
        // left alone — no swap, because `ring_move` finds the focused panel already standing
        // there. One that is NOT up, or that is in a slot no panel shows, falls through to
        // where you are, which is what a line with no `@` at all does.
        if at, held := ring_find(a, doc); held {
            if i := panel_at_spot(a, at); i >= 0 {
                return i
            }
        }
    case .Nth:
        for len(a.panels) < t.panel {
            panel_make(a, len(a.panels))
        }
        return t.panel - 1
    case .Step:
        switch i := a.focus + t.panel; {
        case i < 0:
            return panel_make(a, 0)
        case i >= len(a.panels):
            return panel_make(a, len(a.panels))
        case:
            return i
        }
    case .All: // a reach aims ONE panel; the builtin that means every one refuses it first
    }
    return a.focus
}

// The LIVE panel a target names, for a builtin that acts ON a panel rather than opening into
// one. Nothing is made and no document is asked about: a panel the strip does not have is an
// error here, where `target_reach` would grow the strip until it had one.
target_panel :: proc(a: ^App, t: Target) -> (int, bool) {
    panels_ready(a)
    switch t.how {
    case .Here:
        return a.focus, true
    case .Nth:
        return t.panel - 1, t.panel <= len(a.panels)
    case .Step:
        i := a.focus + t.panel
        return i, i >= 0 && i < len(a.panels)
    case .Showing: // `@=` is an answer about a document, and there is none to ask about
    case .All: // `@*` is every panel; the builtin loops the strip itself (builtin_width)
    }
    return a.focus, false
}

// `@` on its own is resolved here and nowhere else: the picker rewrites it to the `@N` of the
// panel it was steered to, so the line that runs is one the user could have typed and the parse
// above learns no fourth form (PANELS.md §6). Always a copy, because the line the picker holds
// is freed with the state that holds it.
target_aim :: proc(text: string, panel: int) -> string {
    for i in 0 ..< len(text) {
        if text[i] != '@' || i > 0 && !field_sep(text[i - 1]) {
            continue
        }
        if i + 1 == len(text) || field_sep(text[i + 1]) {
            return fmt.tprintf("%s@%d%s", text[:i], panel + 1, text[i + 1:])
        }
    }
    return strings.clone(text, context.temp_allocator)
}

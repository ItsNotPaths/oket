package main

import "../store"
import "../cl"

// The panel a target names, made when the strip does not have it. That is the ring's own rule —
// `ring_put` grows a lane to reach the slot you asked for — and it reads as two here because a
// panel can be named two ways.
//
// `@N` counts from the left, so the strip is extended until there is an Nth panel. `@±N` is a
// WALK from the focused one, and a walk stops at the end it walks into: the panel it makes is
// the one at that end, which is also the only way to say "left of the leftmost". `@=` makes
// none: a panel showing the document either exists or it does not.
target_reach :: proc(a: ^App, t: cl.Target, doc: store.Id) -> int {
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
target_panel :: proc(a: ^App, t: cl.Target) -> (int, bool) {
    panels_ready(a)
    return cl.target_index(t, a.focus, len(a.panels))
}


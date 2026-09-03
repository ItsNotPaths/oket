package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// Addressing (PANELS.md §4). One grammar, and every builtin that takes a target parses it here.
//
//   #N    ring slot N, in the lane the document's kind belongs to
//   @N    panel N, counted from the left of the strip
//   @+N   N panels right of the focused one, @-N N left
//   N     an alias for #N, because that is what `:open <path> 3` meant before there were panels
//   @     the panel the picker was steered to, which only a gesture can name (§6)
//
// The two sigils are §3's two axes and a line may carry one of each: `#N` says which slot holds
// the document, `@N` says which panel stands on it. Neither renumbers the other.
//
// `@N` IS NOT A SLOT NUMBER and never resolves to one here. Aim a panel holding a terminal at a
// file and that panel has to start pointing at an edit slot, possibly one that does not exist
// yet; which slot it lands in stays the kernel's business, the way `kind_fresh` is.

Target :: struct {
    slot:  int, // `#N`. 0: wherever the document's own lane has room for it
    panel: int, // `@N`, or the step in `@±N`. 0: the panel the keys are already aimed at
    rel:   bool,
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
        n, num := strconv.parse_int(body, 10)
        step := body != "" && (body[0] == '+' || body[0] == '-')
        // A step is only a step toward a panel, and no address is zero: `@+0` is the panel you
        // are on, which is what naming no panel already means.
        if !num || n == 0 || (step && !panel) {
            return {}, field, false
        }
        if panel {
            t.panel, t.rel = n, step
        } else {
            t.slot = n
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
// the one at that end, which is also the only way to say "left of the leftmost".
target_reach :: proc(a: ^App, t: Target) -> int {
    panels_ready(a)
    if t.panel == 0 {
        return a.focus
    }
    if !t.rel {
        for len(a.panels) < t.panel {
            panel_make(a, len(a.panels))
        }
        return t.panel - 1
    }
    switch i := a.focus + t.panel; {
    case i < 0:
        return panel_make(a, 0)
    case i >= len(a.panels):
        return panel_make(a, len(a.panels))
    case:
        return i
    }
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

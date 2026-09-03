package main

import "core:strings"
import "../input"

// The picker (PANELS.md §6). Hold a key, press the chord, steer, let the key go:
//
//   1. holding tab does nothing at all — it is not a chord, and no context is entered
//   2. `tab+enter` fires the `pick` row, and the line EXPANDS NOW, so `<path>` reads the field
//      point was on rather than one it may have wandered off
//   3. left and right steer, because arming enters the `[pick]` context
//   4. the chord again MAKES a panel and steers to it — `[pick] tab+enter = :np`, a row
//   5. the release runs the captured line with `@` aimed at the panel steered to
//
// Off a link there is no path, the expansion reports what it cannot fill, and nothing arms.

// Step 2. The chord is what says which key commits, so a row bound with no held key cannot arm
// a gesture nothing would ever finish.
pick_arm :: proc(a: ^App, chord: input.Chord, line: input.Bind_Line) {
    if _, already := a.pending.(input.Pending_Pick); already {
        return // a second gesture over a live one; the first still owns the keys
    }
    if chord.held == 0 {
        message_set(a, "a pick row needs a held key, as in tab+enter")
        return
    }
    text, filled := bind_expand(a, line.text)
    if !filled {
        return // bind_expand said which hole it could not fill
    }
    panels_ready(a)
    input.pending_set(&a.pending, input.Pending_Pick{chord, strings.clone(text), a.focus})
}

// A REPEAT of the arming chord is the key never having come up, and the `[pick]` row it now
// resolves to would make a panel per repeat. Only the caller knows which one it was holding.
pick_armed_by :: proc(a: ^App, chord: input.Chord) -> bool {
    p, armed := a.pending.(input.Pending_Pick)
    return armed && p.chord == chord
}

// Step 3. Clamped to the strip: a walk off the end that MADE a panel would leave one behind
// every time the gesture is cancelled, and `:np` is the row for asking for one on purpose.
pick_step :: proc(a: ^App, by: int) {
    if p, armed := a.pending.(input.Pending_Pick); armed {
        panel_aim(a, p.target + by)
    }
}

// Step 5, from the release of the key the arming chord held. Any other release is somebody
// else's key coming up.
pick_release :: proc(a: ^App, code: input.Code) {
    p, armed := a.pending.(input.Pending_Pick)
    if !armed || p.chord.held != code {
        return
    }
    line := target_aim(p.line, p.target)
    input.pending_set(&a.pending)
    cl_exec(a, line)
}

pick_drop :: proc(a: ^App) {
    if _, armed := a.pending.(input.Pending_Pick); armed {
        input.pending_set(&a.pending)
    }
}

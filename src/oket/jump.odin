package main

import "../store"
import "../txt"
import "../view"

// Where you have been, deep enough to walk. `Panel.prev` is the same idea one entry deep and it
// stays: `alt+\`` is "the last place", `jump.back` is "the way you came".
//
// An entry is the VIEWPORT and not a position (PLAN.md §11): a jump that put you back on the
// line but scrolled somewhere else is a jump you have to redo by hand.
//
// There is no `jump` descriptor field, and §5's own rule is why: a descriptor answers how a
// document is RENDERED or ROUTED, and "is a position here worth returning to" is neither. So
// every focused spot is recorded and nothing opts out. A document that wants to would be the
// first to ask, and one asking is a feature where two would be a field.

JUMP_MAX :: 64

Jump :: struct {
    at:   Spot,
    view: view.View,
}

// `jump_at` is where you are STANDING in the list, and `len(jumps)` means standing past the end
// of it — not walking. Every push truncates the forward half, which is what makes a new jump
// abandon the branch you had walked back out of.
jump_record :: proc(a: ^App, at: Spot, v: view.View) {
    if at.slot < 1 {
        return // slot 0 is standing on nothing, and N# stays at the rotation's edge (§11)
    }
    resize(&a.jumps, a.jump_at)
    if len(a.jumps) > 0 && a.jumps[len(a.jumps) - 1].at == at {
        a.jumps[len(a.jumps) - 1].view = v // the same spot again is a correction, not an entry
        a.jump_at = len(a.jumps)
        return
    }
    append(&a.jumps, Jump{at = at, view = v})
    if len(a.jumps) > JUMP_MAX {
        ordered_remove(&a.jumps, 0)
    }
    a.jump_at = len(a.jumps)
}

jump_back :: proc(a: ^App) {
    if a.jump_at == 0 {
        jump_stuck(a, -1)
        return
    }
    // Standing past the end, so the place you are LEAVING has to go in first or forward would
    // have nothing to come back to.
    if a.jump_at == len(a.jumps) {
        if s := ring_focused(a); s != nil {
            append(&a.jumps, Jump{at = panel_focused(a).at, view = s.view})
        }
    }
    a.jump_at -= 1
    jump_take(a, -1)
}

jump_forward :: proc(a: ^App) {
    if a.jump_at + 1 >= len(a.jumps) {
        jump_stuck(a, +1)
        return
    }
    a.jump_at += 1
    jump_take(a, +1)
}

// Keeps walking in `step` until it finds somewhere to land. Two entries are walked past rather
// than landed on, and for different reasons:
//
//   - the slot has CLOSED. The ring outlives the documents in it, so the entry is dropped for
//     good. Walking back removes the entry under us, which shifts the rest left — hence the
//     extra step; walking on lands the shifted entry at the same index and needs none.
//   - the entry is where you already STAND. Nothing was closed, so the entry keeps its place,
//     but a jump that does not move is one the user reads as broken.
@(private = "file")
jump_take :: proc(a: ^App, step: int) {
    for a.jump_at >= 0 && a.jump_at < len(a.jumps) {
        j := a.jumps[a.jump_at]
        if lane_get(&a.ring, j.at.lane, j.at.slot) == nil {
            ordered_remove(&a.jumps, a.jump_at)
            if step < 0 {
                a.jump_at -= 1
            }
            continue
        }
        if j.at == panel_focused(a).at {
            a.jump_at += step
            continue
        }
        ring_return(a, j.at)
        jump_view(a, j.view)
        return
    }
    a.jump_at = clamp(a.jump_at, 0, len(a.jumps))
    jump_stuck(a, step)
}

@(private = "file")
jump_stuck :: proc(a: ^App, step: int) {
    message_set(a, step < 0 ? "jump.back: nowhere further back" : "jump.forward: nowhere further on")
}

// The viewport, restored against the document as it is NOW. Text moves under a jump ring, so
// both halves are clamped rather than trusted: the caret through the store's own clamp, and
// `top` through the scroll that already refuses to run off the end.
@(private = "file")
jump_view :: proc(a: ^App, v: view.View) {
    s := ring_focused(a)
    if s == nil {
        return
    }
    doc := store.store_doc(&a.docs, s.doc)
    if doc == nil {
        return
    }
    txt.doc_reset_cursor(doc, v.point.head)
    s.view.left = v.left
    s.view.top = v.top
    view.scroll(&s.view, &doc.pt, 0)
    point_sync(a)
}

jumps_free :: proc(a: ^App) {
    delete(a.jumps)
    a.jumps = nil
}

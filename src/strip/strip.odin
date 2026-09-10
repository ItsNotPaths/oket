package strip

import "core:math"

// The strip's CAMERA, and nothing else (PANELS.md §9). Resting slots and a focus index go in,
// where a panel is drawn comes out. Nothing here knows what a document, a kind, a bind or the
// ring is, and its test builds one with a struct literal and no fixture — the check that it
// stayed a piece.
//
// niri's rules, our arithmetic: a horizontal row you scroll, one thing on screen by default,
// and a camera that follows focus by the least it can.
//
// WHERE A PANEL RESTS IS THE LAYOUTER'S (src/lay, CHROME.md §2.1) — including the gap, which is
// what a gap means for any row and not something panels are special about. What is left here is
// the two things RCSS cannot answer: the camera, and the decay that walks between two resting
// layouts on the clock (§7).

// Where a panel sits on the one axis it moves along, in pixels. The other axis is the strip's:
// the strip is one row and does not nest.
Span :: struct {
    x, w: f32,
}

Strip :: struct {
    view:   f32, // what is on screen, in pixels
    camera: f32, // how far the strip has scrolled left, in pixels
    aim:    f32, // where the camera is going; `look_at` answers it and `approach` walks there
    tau:    f32, // seconds the motion decays by 1/e. Zero is motion off: everything lands at once
}

// Half a pixel. Decay never arrives, so below this the destination is assigned and the motion
// ends — or the strip re-renders forever for motion nobody can see (§7).
SNAP :: f32(0.5)

// One step of exponential decay toward a destination, on the CLOCK and not on the frame (§7).
// `1 - exp(-dt/tau)` settles in the same wall time at 60 Hz and at 144, which the frame-count
// form does not, and it never overshoots because that factor is below one for every dt.
approach :: proc(x, dest, dt, tau: f32) -> f32 {
    if tau <= 0 || abs(dest - x) < SNAP {
        return dest
    }
    if dt <= 0 {
        return x
    }
    at := x + (dest - x) * (1 - math.exp(-dt / tau))
    return abs(dest - at) < SNAP ? dest : at
}

// The whole strip, for the camera's far end. The last slot's right edge is flush, because the
// gap came out of the two panels that met at it and never off an end (src/lay).
total :: proc(slots: []Span) -> f32 {
    if len(slots) == 0 {
        return 0
    }
    last := slots[len(slots) - 1]
    return last.x + last.w
}

// Where a panel is DRAWN, on screen: its slot, less the camera. That subtraction is the whole
// of what a camera costs, and it is the one place it is applied.
span :: proc(s: Strip, slots: []Span, i: int) -> Span {
    return {slots[i].x - s.camera, slots[i].w}
}

// The camera that has panel `focus` fully on screen, and the one it already had when it already
// is. Least movement, so this is a strip you scroll and not a carousel that centres.
look_at :: proc(s: Strip, slots: []Span, focus: int) -> f32 {
    if focus < 0 || focus >= len(slots) {
        return s.camera
    }
    it := slots[focus]
    cam := clamp(s.camera, it.x + it.w - s.view, it.x)
    return clamp(cam, 0, max(0, total(slots) - s.view)) // never past either end
}

// Which panel a screen pixel is over: -1 for a gap, and for the space past the last panel. A
// column number means nothing until this has answered (§7).
hit :: proc(s: Strip, slots: []Span, px: f32) -> int {
    for _, i in slots {
        it := span(s, slots, i)
        if px >= it.x && px < it.x + it.w {
            return i
        }
    }
    return -1
}

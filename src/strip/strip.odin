package strip

// The strip's layout, and nothing else (PANELS.md §9). Widths and a focus index go in, pixels
// come out. Nothing here knows what a document, a kind, a bind or the ring is, and its test
// builds one with a struct literal and no fixture — which is the check that it stayed a piece.
//
// niri's rules, our arithmetic: a horizontal row you scroll, one thing on screen by default,
// and a camera that follows focus by the least it can.

// Two widths and no more (§5). A width is a MODE, so sizing is a toggle rather than a drag and
// nobody has to remember a pixel.
Width :: enum u8 {
    Full,
    Half,
}

// Where a panel sits on the one axis it moves along, in pixels. The other axis is the window's:
// the strip is one row and does not nest.
Span :: struct {
    x, w: f32,
}

Strip :: struct {
    view:   f32, // what is on screen, in pixels
    gap:    f32, // between two panels, in pixels
    camera: f32, // how far the strip has scrolled left, in pixels
}

// A width in pixels. Full IS the view, so one-panel mode is a strip of length one rather than a
// special case.
width_px :: proc(s: Strip, w: Width) -> f32 {
    return w == .Half ? s.view / 2 : s.view
}

// A panel's slot in strip coordinates: gaps included, camera not applied. Slots tile the strip
// exactly, which is what keeps two halves worth one full.
slot :: proc(s: Strip, widths: []Width, i: int) -> Span {
    x: f32
    for j in 0 ..< i {
        x += width_px(s, widths[j])
    }
    return {x, width_px(s, widths[i])}
}

// The whole strip, for the camera's far end.
total :: proc(s: Strip, widths: []Width) -> f32 {
    if len(widths) == 0 {
        return 0
    }
    last := slot(s, widths, len(widths) - 1)
    return last.x + last.w
}

// Where a panel is DRAWN, on screen. A gap comes out of the two panels that meet at it, half
// each, so every gap is one width and the strip's own ends stay flush: a strip of one is then
// the full view and looks exactly as it did before there were panels.
span :: proc(s: Strip, widths: []Width, i: int) -> Span {
    it := slot(s, widths, i)
    lo := i > 0 ? s.gap / 2 : 0
    hi := i < len(widths) - 1 ? s.gap / 2 : 0
    return {it.x + lo - s.camera, max(0, it.w - lo - hi)}
}

// The camera that has panel `focus` fully on screen, and the one it already had when it already
// is. Least movement, so this is a strip you scroll and not a carousel that centres.
look_at :: proc(s: Strip, widths: []Width, focus: int) -> f32 {
    if focus < 0 || focus >= len(widths) {
        return s.camera
    }
    it := slot(s, widths, focus)
    cam := clamp(s.camera, it.x + it.w - s.view, it.x)
    return clamp(cam, 0, max(0, total(s, widths) - s.view)) // never past either end
}

// Which panel a screen pixel is over: -1 for a gap, and for the space past the last panel. A
// column number means nothing until this has answered (§7).
hit :: proc(s: Strip, widths: []Width, px: f32) -> int {
    for _, i in widths {
        it := span(s, widths, i)
        if px >= it.x && px < it.x + it.w {
            return i
        }
    }
    return -1
}

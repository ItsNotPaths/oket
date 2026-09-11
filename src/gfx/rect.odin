package gfx

// The package's ONE rectangle, in pixels, sub-pixel. Everything on screen is measured in these:
// a scissor box, a picture's destination, a chrome box, and what src/lay solves.
//
// Sub-pixel is what it is FOR. A panel slides by fractions of a pixel (PANELS.md §7) and a
// gradient's edge lands wherever the solve put it, so the frame's geometry cannot be whole
// pixels without the motion stepping. GL takes integers for a scissor box and nothing else, and
// `painter_scissor` is the one place that rounds.
//
// It counts from the TOP-LEFT of the window, like every rectangle in this package. GL's scissor
// box counts from the bottom-left, which is the other half of what `painter_scissor` is for.
Rect :: struct {
    x, y, w, h: f32,
}

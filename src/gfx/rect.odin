package gfx

// The package's two rectangles, together, because the difference between them is the whole
// reason there are two and it is not visible from either use site.
//
// Both count from the TOP-LEFT of the window, like every rectangle in this package. GL's
// scissor box counts from the bottom-left, and `painter_scissor` is the only place the two
// conventions meet.

// Whole pixels. A scissor box and a picture's destination are both this: nothing is drawn to
// half a pixel and GL's scissor takes integers anyway.
Rect :: struct {
    x, y, w, h: i32,
}

// Sub-pixel, and that is what it is FOR. A panel slides by fractions of a pixel (PANELS.md §7)
// and a gradient's edge lands wherever the solve put it, so the frame's geometry cannot be
// whole pixels without the motion stepping.
Box :: struct {
    x, y, w, h: f32,
}

package gfx

import "core:c"
import "core:math"

// What a chrome rect LOOKS like (CHROME.md §6). src/lay answers where the boxes are; this is
// the whole of what is drawn in them, and between the two there is no toolkit.
//
// A BOX IS TWO ROUNDED RECTS, one inside the other. The outer is the bevel, the inner is the
// fill, and each carries a vertical gradient — which is the entire Clearlooks vocabulary: light
// along the top edge, dark along the bottom, and a one-pixel outline doing the same. Four
// separate edge quads is the obvious shape and it does not survive a corner radius.
//
// NOTHING HERE TOUCHES GL. It appends vertices, so a test counts them with no window and no
// context (§12); `mesher.odin` is what uploads and draws them.

Box :: struct {
    x, y, w, h: f32,
}

// Straight alpha, not premultiplied. The multiply happens at the vertex, which is the one place
// that knows what blend the chrome pass set (§6).
Rgba :: [4]f32

Look :: struct {
    fill:   [2]Rgba, // the fill's vertical gradient: top, then bottom
    edge:   [2]Rgba, // the bevel under it, the same way round
    border: f32, // how far the fill is inset. Zero draws the fill alone
    radius: f32, // the corner, in pixels. Zero is four square corners and no arc at all
}

// Segments per corner arc. Clearlooks rounds by two or three pixels, so four is already finer
// than the lattice can show — and nothing here anti-aliases, so more of them buy nothing.
@(private = "file")
ARC :: 4

// One box's geometry, appended to a frame's list. Two shapes at most, and a box with no border
// is one.
box_mesh :: proc(verts: ^[dynamic]Chrome_Vertex, idx: ^[dynamic]c.int, at: Box, look: Look) {
    if at.w <= 0 || at.h <= 0 {
        return
    }
    if look.border > 0 {
        ring(verts, idx, at, look.radius, look.edge)
    }
    b := look.border
    fill := Box{at.x + b, at.y + b, at.w - 2 * b, at.h - 2 * b}
    if fill.w <= 0 || fill.h <= 0 {
        return // a box thinner than its own bevel is the bevel, which is what a hairline is
    }
    // The inner radius follows the outer one IN. A constant radius would leave the bevel thicker
    // at the corners than along the edges, which is the tell of a border drawn as four quads.
    ring(verts, idx, fill, max(look.radius - b, 0), look.fill)
}

// One rounded rect, its colour lerped down it, as a fan around its own centre. The fan is what
// makes a radius of zero the same code as a radius of four: the ring is simply shorter.
@(private = "file")
ring :: proc(verts: ^[dynamic]Chrome_Vertex, idx: ^[dynamic]c.int,
             at: Box, radius: f32, grad: [2]Rgba) {
    rad := clamp(radius, 0, min(at.w, at.h) / 2)
    hub := c.int(len(verts^))
    append(verts, vertex(at, at.x + at.w / 2, at.y + at.h / 2, grad))

    // Clockwise from the left of the top-left corner, in screen coordinates where y grows down.
    // Each corner stops one step SHORT of the next one's start, so the two never emit the same
    // point twice and the ring closes on itself.
    steps := rad > 0 ? ARC : 1
    for corner in 0 ..< 4 {
        cx := corner == 0 || corner == 3 ? at.x + rad : at.x + at.w - rad
        cy := corner < 2 ? at.y + rad : at.y + at.h - rad
        from := f32(180 + corner * 90)
        for s in 0 ..< steps {
            th := math.to_radians(from + 90 * f32(s) / f32(steps))
            append(verts, vertex(at, cx + math.cos(th) * rad, cy + math.sin(th) * rad, grad))
        }
    }

    n := c.int(4 * steps)
    for i in 0 ..< n {
        append(idx, hub, hub + 1 + i, hub + 1 + (i + 1) % n)
    }
}

// A point on the shape, coloured by how far down the BOX it is — not how far down the ring, so
// a bevel and the fill it wraps agree about where their gradients are.
@(private = "file")
vertex :: proc(at: Box, x, y: f32, grad: [2]Rgba) -> Chrome_Vertex {
    t := at.h > 0 ? clamp((y - at.y) / at.h, 0, 1) : 0
    col := grad[0] + (grad[1] - grad[0]) * t
    q :: proc(v: f32) -> u8 {return u8(clamp(v, 0, 1) * 255 + 0.5)}
    // Premultiplied: the chrome pass blends ONE against ONE_MINUS_SRC_ALPHA (§6). uv stays at
    // the origin, where an untextured quad samples the mesher's one white pixel.
    return {
        x = x,
        y = y,
        r = q(col.r * col.a),
        g = q(col.g * col.a),
        b = q(col.b * col.a),
        a = q(col.a),
    }
}

// A flat box, which is the common one: no bevel, no radius, one colour.
box_flat :: proc(c: [3]f32, alpha: f32 = 1) -> Look {
    rgba := Rgba{c.r, c.g, c.b, alpha}
    return {fill = {rgba, rgba}}
}

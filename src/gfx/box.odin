package gfx

import "core:c"
import "core:math"

// What a chrome rect LOOKS like (CHROME.md §6). src/lay answers where the boxes are; this is
// the whole of what is drawn in them, and between the two there is no toolkit.
//
// A BOX IS TWO ROUNDED OUTLINES, one inside the other. The BAND between them is the bevel and
// the fan inside is the fill, and each carries a vertical gradient — which is the entire
// Clearlooks vocabulary: light along the top edge, dark along the bottom, and a one-pixel
// outline doing the same. Four separate edge quads is the obvious shape and it does not survive
// a corner radius; a band does, and it is still one shape.
//
// NOTHING HERE TOUCHES GL. It appends vertices, so a test counts them with no window and no
// context (§12); `mesher.odin` is what uploads and draws them.

Look :: struct {
    fill:   [2]Rgba, // the fill's vertical gradient: top, then bottom. NOTHING draws no fill
    edge:   [2]Rgba, // the bevel around it, the same way round
    border: f32, // how wide the bevel is. Zero draws the fill alone
    radius: f32, // the corner, in pixels. Zero is four square corners and no arc at all
}

// Segments per corner arc. Clearlooks rounds by two or three pixels, so four is already finer
// than the lattice can show — and nothing here anti-aliases, so more of them buy nothing.
@(private = "file")
ARC :: 4

// One box's geometry, appended to a frame's list. Two shapes at most, and a box with no border
// is one.
box_mesh :: proc(verts: ^[dynamic]Chrome_Vertex, idx: ^[dynamic]c.int, at: Rect, look: Look) {
    if at.w <= 0 || at.h <= 0 {
        return
    }
    // ONE step count for both outlines, so every point on the outer one has its partner on the
    // inner one and the band between them is a quad a step.
    steps := look.radius > 0 ? ARC : 1
    b := look.border
    // The inner radius follows the outer one IN. A constant radius would leave the bevel thicker
    // at the corners than along the edges, which is the tell of a border drawn as four quads.
    fill := Rect{at.x + b, at.y + b, at.w - 2 * b, at.h - 2 * b}
    rad := max(look.radius - b, 0)
    if fill.w <= 0 || fill.h <= 0 {
        fan(verts, idx, at, look.radius, steps, look.edge)
        return // a box thinner than its own bevel is the bevel, which is what a hairline is
    }
    if b > 0 {
        band(verts, idx, at, fill, look.radius, rad, steps, look.edge)
    }
    if look.fill[0].a == 0 && look.fill[1].a == 0 {
        return // a fill that says NOTHING leaves a RING, and what was drawn under it stands
    }
    fan(verts, idx, fill, rad, steps, look.fill)
}

// A filled shape: a fan around its own centre. The fan is what makes a radius of zero the same
// code as a radius of four — the outline is simply shorter.
@(private = "file")
fan :: proc(verts: ^[dynamic]Chrome_Vertex, idx: ^[dynamic]c.int,
            at: Rect, radius: f32, steps: int, grad: [2]Rgba) {
    hub := c.int(len(verts^))
    append(verts, vertex(at, at.x + at.w / 2, at.y + at.h / 2, grad))
    first := outline(verts, at, at, radius, steps, grad)
    n := c.int(4 * steps)
    for i in 0 ..< n {
        append(idx, hub, first + i, first + (i + 1) % n)
    }
}

// The bevel: the band between the box's outline and the fill's, a quad a step. Both ends of it
// are coloured down the OUTER box, so the ring reads as one edge and not as two.
@(private = "file")
band :: proc(verts: ^[dynamic]Chrome_Vertex, idx: ^[dynamic]c.int,
             at, inner: Rect, radius, in_radius: f32, steps: int, grad: [2]Rgba) {
    out := outline(verts, at, at, radius, steps, grad)
    in_ := outline(verts, at, inner, in_radius, steps, grad)
    n := c.int(4 * steps)
    for i in 0 ..< n {
        next := (i + 1) % n
        append(idx, out + i, out + next, in_ + i)
        append(idx, in_ + i, out + next, in_ + next)
    }
}

// One rounded outline's points, clockwise from the left of the top-left corner, in screen
// coordinates where y grows down. Each corner stops one step SHORT of the next one's start, so
// the two never emit the same point twice and the outline closes on itself. `grad_box` is what
// the colour is lerped down, which is not always the shape's own box.
@(private = "file")
outline :: proc(verts: ^[dynamic]Chrome_Vertex, grad_box, at: Rect,
                radius: f32, steps: int, grad: [2]Rgba) -> c.int {
    rad := clamp(radius, 0, min(at.w, at.h) / 2)
    first := c.int(len(verts^))
    for corner in 0 ..< 4 {
        cx := corner == 0 || corner == 3 ? at.x + rad : at.x + at.w - rad
        cy := corner < 2 ? at.y + rad : at.y + at.h - rad
        from := f32(180 + corner * 90)
        for s in 0 ..< steps {
            th := math.to_radians(from + 90 * f32(s) / f32(steps))
            append(verts, vertex(grad_box, cx + math.cos(th) * rad, cy + math.sin(th) * rad,
                                 grad))
        }
    }
    return first
}

// A point on the shape, coloured by how far down the BOX it is — not how far down the outline,
// so a bevel and the fill it wraps agree about where their gradients are.
@(private = "file")
vertex :: proc(at: Rect, x, y: f32, grad: [2]Rgba) -> Chrome_Vertex {
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

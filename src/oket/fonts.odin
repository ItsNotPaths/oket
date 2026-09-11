package main

import "core:fmt"
import "../font"
import "../gfx"

FONT_PT_FALLBACK :: 12.0 // points; the 96dpi/72pt conversion below is what every toolkit uses

// Opens the faces of the grabbed stack at the size the system named, which comes back because
// a zoom step counts from it. Temporary: once config.conf names the stack this reads it from
// there (§4).
font_stack_load :: proc(scale: f32) -> (faces: []gfx.Face, used: int) {
    stack, ok := font.grab()
    if !ok {
        return nil, 0
    }
    defer stack_free(stack)

    used = stack_px(stack, scale)
    out := make([dynamic]gfx.Face)
    for e in stack {
        // A failed open is skipped, not fatal: the bundled bitmap is behind everything.
        if f, opened := gfx.face_open(e.path, used); opened {
            append(&out, f)
        }
    }
    if len(out) == 0 {
        delete(out)
        return nil, used
    }
    return out[:], used
}

@(private = "file")
stack_px :: proc(stack: []font.Entry, scale: f32) -> int {
    pt := stack[0].size > 0 ? stack[0].size : FONT_PT_FALLBACK
    return int(pt * 96.0 / 72.0 * scale + 0.5)
}

@(private = "file")
stack_free :: proc(stack: []font.Entry) {
    for e in stack {
        delete(e.family)
        delete(e.path)
    }
    delete(stack)
}

// The zoom, and it is the atlas that changes rather than the layout: the frame loop re-fits
// the grids from the window every frame, so a new size relays itself. The viewport is view
// state and survives it, the same way it survives a resize (§11).

// The size baked into the atlas now, and the one the display asked for at startup.
font_init :: proc(a: ^App, px: int) {
    a.font_px, a.font_system = px, px
}

// Rebakes the atlas in place at `px`. A size out of range, the one already baked, or the
// fallback bitmap leaves the screen exactly as it was.
font_apply :: proc(a: ^App, px: int) -> bool {
    if px == a.font_px || !gfx.face_px_ok(px) {
        return false
    }
    gfx.atlas_resize(&a.painter.atlas, px) or_return
    a.font_px = px
    return true
}

// All three zoom verbs report rather than go quiet, because a bound chord that does nothing is
// what §8 exists to prevent. The fallback bitmap is the case they share.
@(private = "file")
NO_FACE :: "the built-in bitmap has one size; there is no system font to resize"

// ctrl+= and ctrl+-.
font_zoom :: proc(a: ^App, dir: int) {
    if gfx.atlas_is_fallback(&a.painter.atlas) {
        message_set(a, NO_FACE)
        return
    }
    px := gfx.face_next_px(&a.painter.atlas.faces[0], a.font_px, dir)
    if !font_apply(a, px) {
        message_set(a, fmt.tprintf("%d px is as %s as the font goes", a.font_px,
                                   dir > 0 ? "big" : "small"))
    }
}

// ctrl+0, back to the baseline: the size `[font] size` named, or the display's own when it
// named none.
font_reset :: proc(a: ^App) {
    if font_apply(a, a.font_system) {
        return
    }
    if gfx.atlas_is_fallback(&a.painter.atlas) {
        message_set(a, NO_FACE)
        return
    }
    message_set(a, fmt.tprintf("already at %d px", a.font_px))
}

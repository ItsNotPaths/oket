package main

import "../font"
import "../gfx"

FONT_PT_FALLBACK :: 12.0 // points; the 96dpi/72pt conversion below is what every toolkit uses

// Opens the faces of the grabbed stack, at `px` when a size in range is asked for and at the
// size the system named otherwise. The size used comes back, because a zoom step counts from it.
// Temporary: once config.conf names the stack this reads it from there (§4).
font_stack_load :: proc(scale: f32, px := 0) -> (faces: []gfx.Face, used: int) {
    stack, ok := font.grab()
    if !ok {
        return nil, 0
    }
    defer stack_free(stack)

    used = gfx.face_px_ok(px) ? px : stack_px(stack, scale)
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

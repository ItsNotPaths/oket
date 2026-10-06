package gfx

import "../font"

@(private = "file")
PT_FALLBACK :: 12.0 // points; the 96dpi/72pt conversion below is what every toolkit uses

// Opens the faces of the grabbed stack at the size the system named, which comes back because
// a zoom step counts from it. Temporary: once config.conf names the stack this reads it from
// there (§4).
face_stack_load :: proc(scale: f32) -> (faces: []Face, used: int) {
    stack, ok := font.grab()
    if !ok {
        return nil, 0
    }
    defer stack_free(stack)

    used = stack_px(stack, scale)
    out := make([dynamic]Face)
    for e in stack {
        // A failed open is skipped, not fatal: the bundled bitmap is behind everything.
        if f, opened := face_open(e.path, used); opened {
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
    pt := stack[0].size > 0 ? stack[0].size : PT_FALLBACK
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

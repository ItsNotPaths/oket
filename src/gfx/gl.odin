package gfx

import "core:math"
import gl "vendor:OpenGL"

// The version the painter's shaders are written against. The front-end asks its window for a
// context matching this rather than picking a number of its own.
GL_MAJOR :: 3
GL_MINOR :: 3

// The loader is the window system's symbol lookup; main wraps SDL's GL_GetProcAddress. Call
// before any other GL, so nothing above gfx needs the GL package.
gl_init :: proc(loader: proc(p: rawptr, name: cstring)) {
    gl.load_up_to(GL_MAJOR, GL_MINOR, loader)
}

gl_clear :: proc(win_w, win_h: i32, bg: [3]f32) {
    gl.Viewport(0, 0, win_w, win_h)
    gl.ClearColor(bg.r, bg.g, bg.b, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
}

// A flat opaque rect, snapped to whole pixels. A scissored clear, so no program and no blend.
fill :: proc(r: Rect, rgb: [3]f32, win_h: i32) {
    x0, y0 := i32(math.round(r.x)), i32(math.round(r.y))
    x1, y1 := i32(math.round(r.x + r.w)), i32(math.round(r.y + r.h))
    if x1 <= x0 || y1 <= y0 {
        return
    }
    gl.Enable(gl.SCISSOR_TEST)
    defer gl.Disable(gl.SCISSOR_TEST)
    gl.Scissor(x0, win_h - y1, x1 - x0, y1 - y0)
    gl.ClearColor(rgb.r, rgb.g, rgb.b, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
}

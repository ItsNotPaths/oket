package gfx

import gl "vendor:OpenGL"

// The version the painter's shaders are written against. The front-end asks its window for a
// context matching this rather than picking a number of its own.
GL_MAJOR :: 3
GL_MINOR :: 3

// The loader is the window system's symbol lookup; GLFW's is `glfw.gl_set_proc_address`. Call
// before any other GL, so nothing above gfx needs the GL package.
gl_init :: proc(loader: proc(p: rawptr, name: cstring)) {
    gl.load_up_to(GL_MAJOR, GL_MINOR, loader)
}

gl_clear :: proc(win_w, win_h: i32, bg: [3]f32) {
    gl.Viewport(0, 0, win_w, win_h)
    gl.ClearColor(bg.r, bg.g, bg.b, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
}

package gfx

import "core:c"
import "core:fmt"
import gl "vendor:OpenGL"

// The frame's pass (CHROME.md §6): a third GL program beside the cell painter and the image
// blitter. src/lay says where the frame's boxes are and gfx/box.odin turns one into vertices;
// this uploads them and draws them.
//
// ONE MESH FOR THE WHOLE FRAME. It changes on settle and all of it is a few hundred vertices,
// so it is one buffer rewritten and one draw call — not a handle per box for somebody to
// release, and no retained geometry to keep in step with a layout.

// What the attribute pointers below read, by hand. The colour arrives PREMULTIPLIED, which is
// why the pass brackets its own blend.
Chrome_Vertex :: struct {
    x, y:       f32,
    r, g, b, a: u8,
    u, v:       f32,
}

#assert(size_of(Chrome_Vertex) == 20)

@(private = "file")
VERT :: `#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec4 a_col;
layout(location = 2) in vec2 a_uv;

uniform vec2 u_screen_px;
uniform vec2 u_translate_px;

out vec4 v_col;
out vec2 v_uv;

void main() {
    vec2 px = a_pos + u_translate_px;
    gl_Position = vec4(px.x / u_screen_px.x * 2.0 - 1.0,
                       1.0 - px.y / u_screen_px.y * 2.0, 0.0, 1.0);
    v_col = a_col;
    v_uv = a_uv;
}
`

// The sampler is the seat for atlas text: a box is untextured and samples one white pixel, and a
// rune drawn in a box would sample the cell painter's atlas, which is R8 coverage. One program
// answers both, and a second with no sampler in it would buy nothing.
@(private = "file")
FRAG :: `#version 330 core
in vec4 v_col;
in vec2 v_uv;

uniform sampler2D u_tex;
uniform int u_cover; // the atlas is R8 coverage; every other texture is RGBA

out vec4 o_color;

void main() {
    vec4 t = texture(u_tex, v_uv);
    o_color = u_cover != 0 ? v_col * t.r : v_col * t;
}
`

@(private = "file")
Mesh :: struct {
    vao, vbo, ibo: u32,
}

Mesher :: struct {
    prog:                           u32,
    white:                          u32, // 1x1, what an untextured quad samples
    own:                            Mesh,
    u_screen, u_translate, u_cover: i32,
}

mesher_init :: proc(m: ^Mesher) -> bool {
    prog, ok := gl.load_shaders_source(VERT, FRAG)
    if !ok {
        fmt.eprintln("mesher: shader compilation failed")
        return false
    }
    m.prog = prog

    white := [4]u8{255, 255, 255, 255}
    gl.GenTextures(1, &m.white)
    gl.BindTexture(gl.TEXTURE_2D, m.white)
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, &white[0])
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.BindTexture(gl.TEXTURE_2D, 0)

    gl.UseProgram(m.prog)
    m.u_screen = gl.GetUniformLocation(m.prog, "u_screen_px")
    m.u_translate = gl.GetUniformLocation(m.prog, "u_translate_px")
    m.u_cover = gl.GetUniformLocation(m.prog, "u_cover")
    gl.Uniform1i(gl.GetUniformLocation(m.prog, "u_tex"), 0) // sampler -> unit 0
    return true
}

mesher_destroy :: proc(m: ^Mesher) {
    if m.prog == 0 {
        return
    }
    mesh_free(&m.own)
    gl.DeleteTextures(1, &m.white)
    gl.DeleteProgram(m.prog)
    m^ = {}
}

// The blend bracket (§6): both of the programs beside this one are straight alpha and a box's
// colour arrives premultiplied, so the pass sets its own state and puts it back.
mesher_begin :: proc(m: ^Mesher, win_w, win_h: i32) {
    if m.prog == 0 {
        return
    }
    gl.UseProgram(m.prog)
    gl.Uniform2f(m.u_screen, f32(win_w), f32(win_h))
    gl.Uniform2f(m.u_translate, 0, 0) // a box carries its own origin
    gl.Uniform1i(m.u_cover, 0)
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, m.white)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
}

mesher_end :: proc(m: ^Mesher) {
    if m.prog == 0 {
        return
    }
    gl.Disable(gl.BLEND)
    gl.BindVertexArray(0)
}

// A frame of boxes, uploaded and drawn. Between a begin and an end, like every other pass
// through this program. DYNAMIC_DRAW, because this one buffer is rewritten whenever the frame
// moves rather than compiled once.
mesher_paint :: proc(m: ^Mesher, verts: []Chrome_Vertex, idx: []c.int) {
    if m.prog == 0 || len(verts) == 0 || len(idx) == 0 {
        return
    }
    if m.own.vao == 0 {
        gl.GenVertexArrays(1, &m.own.vao)
        gl.GenBuffers(1, &m.own.vbo)
        gl.GenBuffers(1, &m.own.ibo)
        gl.BindVertexArray(m.own.vao)
        gl.BindBuffer(gl.ARRAY_BUFFER, m.own.vbo)
        // Bound while the VAO is: the element buffer is the VAO's own state, so a draw binds
        // one object and not three.
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, m.own.ibo)
        attribs()
    }
    gl.BindVertexArray(m.own.vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, m.own.vbo)
    gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of(Chrome_Vertex), raw_data(verts),
                  gl.DYNAMIC_DRAW)
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, m.own.ibo)
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(idx) * size_of(c.int), raw_data(idx),
                  gl.DYNAMIC_DRAW)
    gl.DrawElements(gl.TRIANGLES, i32(len(idx)), gl.UNSIGNED_INT, nil)
}

// The vertex layout, read by hand: these pointers ARE what Chrome_Vertex means to the GPU.
// Called with the mesh's own VAO bound, because that is the object they are recorded into.
@(private = "file")
attribs :: proc() {
    stride := i32(size_of(Chrome_Vertex))
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 2, gl.FLOAT, false, stride, offset_of(Chrome_Vertex, x))
    // Normalized: the colour is four bytes on the wire and 0..1 in the shader.
    gl.EnableVertexAttribArray(1)
    gl.VertexAttribPointer(1, 4, gl.UNSIGNED_BYTE, true, stride, offset_of(Chrome_Vertex, r))
    gl.EnableVertexAttribArray(2)
    gl.VertexAttribPointer(2, 2, gl.FLOAT, false, stride, offset_of(Chrome_Vertex, u))
}

@(private = "file")
mesh_free :: proc(mesh: ^Mesh) {
    if mesh.vao == 0 {
        return
    }
    gl.DeleteBuffers(1, &mesh.vbo)
    gl.DeleteBuffers(1, &mesh.ibo)
    gl.DeleteVertexArrays(1, &mesh.vao)
    mesh^ = {}
}

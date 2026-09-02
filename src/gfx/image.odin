package gfx

import "core:math"
import gl "vendor:OpenGL"

// The picture lane, beside the cell painter. Taken from Slopd's gl_image.odin and the image
// pass in its gl_draw.odin, with the pane plumbing dropped.
//
// It cannot ride the painter's pass: that one is R8, one instanced quad per cell, and its
// geometry comes from a cell index. A picture is RGBA at an arbitrary pixel rect. So a second
// program, drawn AFTER the cells, which is what lets a surface write blanks and show pictures
// through them.

Rect :: struct {
    x, y, w, h: i32,
}

// A texture the GPU holds and the size it was uploaded at. handle 0 is nothing.
Image :: struct {
    handle: u32,
    w, h:   i32,
}

image_valid :: proc(img: Image) -> bool {
    return img.handle != 0
}

// RGBA8, linear-filtered, clamped: a photo scaled into a rect, not a tiled texture. The atlas
// is NEAREST for the opposite reason — a glyph is sampled at exactly its baked size, a picture
// almost never is. Must run on the GL thread.
image_upload :: proc(pixels: rawptr, w, h: i32) -> (Image, bool) {
    if pixels == nil || w <= 0 || h <= 0 {
        return {}, false
    }
    tex: u32
    gl.GenTextures(1, &tex)
    if tex == 0 {
        return {}, false
    }
    gl.BindTexture(gl.TEXTURE_2D, tex)
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.BindTexture(gl.TEXTURE_2D, 0)
    return Image{handle = tex, w = w, h = h}, true
}

image_free :: proc(img: ^Image) {
    if img.handle != 0 {
        gl.DeleteTextures(1, &img.handle)
    }
    img^ = {}
}

// One picture and where it goes. The source is the whole texture, so only the rect varies.
Image_Quad :: struct {
    img:   Image,
    dst:   Rect,
    angle: f32, // radians, clockwise about the rect's centre; 0 is upright
}

@(private = "file")
VERT :: `#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
uniform vec2 u_screen_px;
out vec2 v_uv;
void main() {
    gl_Position = vec4(a_pos.x / u_screen_px.x * 2.0 - 1.0,
                       1.0 - a_pos.y / u_screen_px.y * 2.0, 0.0, 1.0);
    v_uv = a_uv;
}
`

@(private = "file")
FRAG :: `#version 330 core
in vec2 v_uv;
uniform sampler2D u_img;
out vec4 o_color;
void main() {
    o_color = texture(u_img, v_uv);
}
`

Blitter :: struct {
    prog:     u32,
    vao, vbo: u32,
    u_screen: i32,
}

blitter_init :: proc(b: ^Blitter) -> bool {
    prog, ok := gl.load_shaders_source(VERT, FRAG)
    if !ok {
        return false
    }
    b.prog = prog

    gl.GenVertexArrays(1, &b.vao)
    gl.GenBuffers(1, &b.vbo)
    gl.BindVertexArray(b.vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, b.vbo)
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 16, 0)
    gl.EnableVertexAttribArray(1)
    gl.VertexAttribPointer(1, 2, gl.FLOAT, false, 16, 8)
    gl.BindVertexArray(0)

    gl.UseProgram(b.prog)
    b.u_screen = gl.GetUniformLocation(b.prog, "u_screen_px")
    gl.Uniform1i(gl.GetUniformLocation(b.prog, "u_img"), 0) // sampler -> unit 0
    return true
}

blitter_destroy :: proc(b: ^Blitter) {
    gl.DeleteBuffers(1, &b.vbo)
    gl.DeleteVertexArrays(1, &b.vao)
    gl.DeleteProgram(b.prog)
    b^ = {}
}

// One DrawArrays per picture: each carries its own texture, so they cannot batch. Blended, so
// a PNG's alpha shows the cells underneath. `clip` is in the same top-left pixel space as the
// rects; the scissor's origin is bottom-left, hence the flip. Later quads draw over earlier
// ones, which is what makes document order the stacking order.
blitter_draw :: proc(b: ^Blitter, quads: []Image_Quad, clip: Rect, win_w, win_h: i32) {
    if len(quads) == 0 || b.prog == 0 || clip.w <= 0 || clip.h <= 0 {
        return // prog 0 is a blitter whose shader never compiled; it draws nothing
    }
    gl.UseProgram(b.prog)
    gl.Uniform2f(b.u_screen, f32(win_w), f32(win_h))
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
    gl.Enable(gl.SCISSOR_TEST)
    gl.Scissor(clip.x, win_h - (clip.y + clip.h), clip.w, clip.h)
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindVertexArray(b.vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, b.vbo)

    for q in quads {
        if !image_valid(q.img) || q.dst.w <= 0 || q.dst.h <= 0 {
            continue
        }
        // The four corners, spun about the centre. Rotation is two trig calls and eight
        // multiply-adds a picture, which is why the format carries an angle rather than asking
        // a caller to bake one into its pixels: at zero it collapses to the plain rect exactly.
        cx := f32(q.dst.x) + f32(q.dst.w) / 2
        cy := f32(q.dst.y) + f32(q.dst.h) / 2
        hw, hh := f32(q.dst.w) / 2, f32(q.dst.h) / 2
        cos, sin := math.cos(q.angle), math.sin(q.angle)
        x0, y0 := cx - hw * cos + hh * sin, cy - hw * sin - hh * cos
        x1, y1 := cx + hw * cos + hh * sin, cy + hw * sin - hh * cos
        x2, y2 := cx + hw * cos - hh * sin, cy + hw * sin + hh * cos
        x3, y3 := cx - hw * cos - hh * sin, cy - hw * sin + hh * cos
        // uv (0,0) is the picture's top: stb decodes top-down.
        verts := [?]f32 {
            x0, y0, 0, 0,  x1, y1, 1, 0,  x2, y2, 1, 1,
            x0, y0, 0, 0,  x2, y2, 1, 1,  x3, y3, 0, 1,
        }
        gl.BindTexture(gl.TEXTURE_2D, q.img.handle)
        gl.BufferData(gl.ARRAY_BUFFER, size_of(verts), &verts[0], gl.STREAM_DRAW)
        gl.DrawArrays(gl.TRIANGLES, 0, 6)
    }

    gl.Disable(gl.SCISSOR_TEST)
    gl.Disable(gl.BLEND)
}

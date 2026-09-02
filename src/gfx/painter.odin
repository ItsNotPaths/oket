package gfx

import "core:fmt"
import gl "vendor:OpenGL"

// Puts a Grid and an Atlas on the GPU; the only code that talks to OpenGL beyond gl.odin.
// One instanced draw for the whole screen: a unit quad per cell, background and glyph in the
// same pass. The grid uploads whole every frame (~860 KB at 300x80); per-cell damage
// tracking waits for evidence it is needed.

@(private = "file")
VERT :: `#version 330 core
layout(location = 0) in vec2 i_cell;
layout(location = 1) in uint i_slot;
layout(location = 2) in vec3 i_fg;
layout(location = 3) in vec3 i_bg;
layout(location = 4) in uint i_attrs;

uniform vec2 u_cell_px;
uniform vec2 u_screen_px;
uniform vec2 u_origin_px;
uniform vec2 u_slots;

out vec2 v_uv;
out vec3 v_fg;
out vec3 v_bg;
out vec2 v_at; // where in the cell this fragment is, which is what an underline needs
flat out uint v_attrs;

void main() {
    // The quad's corners come from the vertex id, so there is no vertex buffer to bind.
    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    vec2 px = u_origin_px + (i_cell + corner) * u_cell_px;
    gl_Position = vec4(px.x / u_screen_px.x * 2.0 - 1.0,
                       1.0 - px.y / u_screen_px.y * 2.0, 0.0, 1.0);

    vec2 slot = vec2(mod(float(i_slot), u_slots.x), floor(float(i_slot) / u_slots.x));
    v_uv = (slot + corner) / u_slots;
    v_fg = i_fg;
    v_bg = i_bg;
    v_at = corner;
    v_attrs = i_attrs;
}
`

@(private = "file")
FRAG :: `#version 330 core
in vec2 v_uv;
in vec3 v_fg;
in vec3 v_bg;
in vec2 v_at;
flat in uint v_attrs;

uniform sampler2D u_atlas;
uniform vec2 u_cell_px;

out vec4 o_color;

// gfx.Attr's bits. Reverse is swapped before upload, and bold and italic want a face this
// atlas does not hold, so the underline is the only one the shader answers.
const uint ATTR_UNDERLINE = 4u;

void main() {
    vec3 c = mix(v_bg, v_fg, texture(u_atlas, v_uv).r);
    // Two pixels along the cell's bottom edge, so it stays visible as the cell zooms.
    if ((v_attrs & ATTR_UNDERLINE) != 0u && v_at.y > 1.0 - 2.0 / u_cell_px.y) {
        c = v_fg;
    }
    o_color = vec4(c, 1.0);
}
`

// One cell as the GPU sees it; memcpy'd straight into the instance buffer.
@(private = "file")
Quad :: struct {
    cell:  [2]f32,
    slot:  u32,
    fg:    [3]f32,
    bg:    [3]f32,
    attrs: u32,
}

Painter :: struct {
    prog:            u32,
    vao, vbo, tex:   u32,
    atlas:           Atlas,
    quads:           [dynamic]Quad,
    // Whole numbers only: a fractional cell size stops being exact arithmetic.
    scale:           f32,
    u_cell, u_screen, u_origin, u_slots, u_atlas: i32,
}

painter_init :: proc(p: ^Painter, atlas: Atlas) -> bool {
    prog, ok := gl.load_shaders_source(VERT, FRAG)
    if !ok {
        fmt.eprintln("painter: shader compilation failed")
        return false
    }
    p.prog = prog
    p.atlas = atlas
    p.scale = 1

    gl.GenVertexArrays(1, &p.vao)
    gl.GenBuffers(1, &p.vbo)
    gl.BindVertexArray(p.vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, p.vbo)

    stride := i32(size_of(Quad))
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 2, gl.FLOAT, false, stride, offset_of(Quad, cell))
    gl.EnableVertexAttribArray(1)
    // Integer attribute: VertexAttribPointer would silently convert it to a float.
    gl.VertexAttribIPointer(1, 1, gl.UNSIGNED_INT, stride, offset_of(Quad, slot))
    gl.EnableVertexAttribArray(2)
    gl.VertexAttribPointer(2, 3, gl.FLOAT, false, stride, offset_of(Quad, fg))
    gl.EnableVertexAttribArray(3)
    gl.VertexAttribPointer(3, 3, gl.FLOAT, false, stride, offset_of(Quad, bg))
    gl.EnableVertexAttribArray(4)
    gl.VertexAttribIPointer(4, 1, gl.UNSIGNED_INT, stride, offset_of(Quad, attrs))
    for i in u32(0) ..= 4 {
        gl.VertexAttribDivisor(i, 1) // one set of attributes per cell, not per vertex
    }

    gl.GenTextures(1, &p.tex)
    gl.BindTexture(gl.TEXTURE_2D, p.tex)
    painter_upload_all(p)
    // NEAREST: everything is sampled at exactly its baked size, so filtering could only blur.
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

    gl.UseProgram(p.prog)
    p.u_cell = gl.GetUniformLocation(p.prog, "u_cell_px")
    p.u_screen = gl.GetUniformLocation(p.prog, "u_screen_px")
    p.u_origin = gl.GetUniformLocation(p.prog, "u_origin_px")
    p.u_slots = gl.GetUniformLocation(p.prog, "u_slots")
    p.u_atlas = gl.GetUniformLocation(p.prog, "u_atlas")
    gl.Uniform1i(p.u_atlas, 0)
    return true
}

// The whole texture: init and atlas growth only. UNPACK_ALIGNMENT 1, or the default 4-byte
// alignment shears any atlas whose width is not a multiple of 4.
@(private = "file")
painter_upload_all :: proc(p: ^Painter) {
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
    gl.TexImage2D(
        gl.TEXTURE_2D, 0, gl.R8,
        i32(atlas_width(&p.atlas)), i32(atlas_height(&p.atlas)), 0,
        gl.RED, gl.UNSIGNED_BYTE, raw_data(p.atlas.pixels),
    )
    p.atlas.resized = false
    clear(&p.atlas.dirty)
}

// Pushes glyphs baked since the last frame. UNPACK_ROW_LENGTH lets each cell upload straight
// out of the atlas, with no contiguous staging copy.
@(private = "file")
painter_sync :: proc(p: ^Painter) {
    if p.atlas.resized {
        painter_upload_all(p)
        return
    }
    if len(p.atlas.dirty) == 0 {
        return
    }
    w := atlas_width(&p.atlas)
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
    gl.PixelStorei(gl.UNPACK_ROW_LENGTH, i32(w))
    for slot in p.atlas.dirty {
        ox, oy := atlas_origin(&p.atlas, slot)
        gl.TexSubImage2D(
            gl.TEXTURE_2D, 0, i32(ox), i32(oy), i32(p.atlas.cell_w), i32(p.atlas.cell_h),
            gl.RED, gl.UNSIGNED_BYTE, raw_data(p.atlas.pixels[oy * w + ox:]),
        )
    }
    gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
    clear(&p.atlas.dirty)
}

painter_destroy :: proc(p: ^Painter) {
    gl.DeleteTextures(1, &p.tex)
    gl.DeleteBuffers(1, &p.vbo)
    gl.DeleteVertexArrays(1, &p.vao)
    gl.DeleteProgram(p.prog)
    delete(p.quads)
    atlas_destroy(&p.atlas)
    p^ = {}
}

painter_set_scale :: proc(p: ^Painter, scale: f32) {
    p.scale = max(1, f32(int(scale))) // floored to a whole number, never below 1
}

// The cell as drawn: the atlas's own size, times the whole-number scale the bitmap fallback
// zooms by. One answer, so the fit and the projection cannot disagree.
painter_cell :: proc(p: ^Painter) -> (w, h: int) {
    return int(f32(p.atlas.cell_w) * p.scale), int(f32(p.atlas.cell_h) * p.scale)
}

// Where the grid's top-left corner sits. A whole number of cells almost never fills a window
// exactly, and the remainder is split evenly rather than left along the right and bottom edges:
// the mismatch then reads as a border and not as the grid having slipped. Under one cell in
// each axis, so the two margins differ by at most the odd pixel.
painter_origin :: proc(p: ^Painter, win_w, win_h: i32, cols, rows: int) -> (x, y: int) {
    w, h := painter_cell(p)
    return max(0, (int(win_w) - w * cols) / 2), max(0, (int(win_h) - h * rows) / 2)
}

// Cells the grid holds at the painter's cell size, for the window it is drawn into.
painter_fit :: proc(p: ^Painter, win_w, win_h: i32) -> (cols, rows: int) {
    w, h := painter_cell(p)
    return max(1, int(win_w) / w), max(1, int(win_h) / h)
}

painter_draw :: proc(p: ^Painter, g: ^Grid, win_w, win_h: i32) {
    clear(&p.quads)
    for y in 0 ..< g.rows {
        for x in 0 ..< g.cols {
            c := g.cells[y * g.cols + x]
            // Reverse is a swap and needs no shader branch; the rest ride along as bits.
            fg, bg := c.fg, c.bg
            if .Reverse in c.attrs {
                fg, bg = bg, fg
            }
            // ensure, not slot: this is what makes the atlas lazy rather than pre-filled.
            append(
                &p.quads,
                Quad {
                    {f32(x), f32(y)},
                    u32(atlas_ensure(&p.atlas, c.r)),
                    fg,
                    bg,
                    u32(transmute(u8)c.attrs),
                },
            )
        }
    }
    if len(p.quads) == 0 {
        return
    }

    gl.UseProgram(p.prog)
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, p.tex)
    painter_sync(p) // after ensure: this frame's new glyphs go up before it draws
    gl.BindVertexArray(p.vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, p.vbo)
    gl.BufferData(gl.ARRAY_BUFFER, len(p.quads) * size_of(Quad), raw_data(p.quads), gl.STREAM_DRAW)

    cw, ch := painter_cell(p)
    ox, oy := painter_origin(p, win_w, win_h, g.cols, g.rows)
    gl.Uniform2f(p.u_cell, f32(cw), f32(ch))
    gl.Uniform2f(p.u_screen, f32(win_w), f32(win_h))
    gl.Uniform2f(p.u_origin, f32(ox), f32(oy))
    gl.Uniform2f(p.u_slots, f32(p.atlas.cols), f32(p.atlas.rows))

    gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, i32(len(p.quads)))
}

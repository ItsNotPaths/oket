package gfx

import tt "vendor:stb/truetype"

// A loaded font file, ready to rasterize into atlas cells. The PRIMARY face dictates the
// cell; every other face in the stack is fitted into it rather than setting its own.

Face :: struct {
    data:     []u8, // the mapped file; stbtt reads through it, so it outlives the load
    info:     tt.fontinfo,
    scale:    f32,  // font units to pixels
    baseline: int,  // rows from the top of the cell down to the baseline
}

// `px` is the cell height, ascent to descent; face_cell adds the line gap on top.
face_open :: proc(path: string, px: int) -> (f: Face, ok: bool) {
    data := face_map(path) or_return
    offset := tt.GetFontOffsetForIndex(raw_data(data), 0)
    if offset < 0 || !tt.InitFont(&f.info, raw_data(data), offset) {
        face_unmap(data)
        return {}, false
    }
    f.data = data
    f.scale = tt.ScaleForPixelHeight(&f.info, f32(px))
    return f, true
}

face_close :: proc(f: ^Face) {
    face_unmap(f.data)
    f^ = {}
}

// The cell this face wants. Only the primary's answer is used; the rest are fitted to it.
face_cell :: proc(f: ^Face) -> (w, h, baseline: int) {
    return face_cell_at(f, f.scale)
}

// The same, at a scale the face has not moved to: a zoom step measures several candidate sizes
// before it picks one, and measuring must not disturb what is on screen.
face_cell_at :: proc(f: ^Face, scale: f32) -> (w, h, baseline: int) {
    ascent, descent, gap: i32
    tt.GetFontVMetrics(&f.info, &ascent, &descent, &gap)
    adv, lsb: i32
    // 'M': on a monospace face every advance matches, and otherwise it is the widest case.
    tt.GetCodepointHMetrics(&f.info, 'M', &adv, &lsb)

    w = int(f32(adv) * scale + 0.5)
    h = int((f32(ascent) - f32(descent) + f32(gap)) * scale + 0.5)
    baseline = int(f32(ascent) * scale + 0.5)
    return max(w, 1), max(h, 1), baseline
}

// The same mapped file at another pixel size. Only the scale moves: the file stays mapped and
// its tables stay parsed, so a resize costs a multiply rather than a re-open.
face_resize :: proc(f: ^Face, px: int) {
    f.scale = tt.ScaleForPixelHeight(&f.info, f32(px))
}

// Below the floor a glyph stops being one; above the ceiling a single cell fills a window and
// the atlas at that size is megabytes.
FACE_PX_MIN :: 6
FACE_PX_MAX :: 200

// A size the atlas can actually hold. Not only the zoom command's guard: a size read back from
// config.toml is hand-editable, and a 5000px face is a 19 GB atlas allocated before the first
// frame ever draws.
face_px_ok :: proc(px: int) -> bool {
    return px >= FACE_PX_MIN && px <= FACE_PX_MAX
}

// The next size in `dir` whose cell WIDTH differs. An advance rounds to whole pixels, so
// several sizes share a width; walking past that plateau is what makes every zoom step move
// the grid instead of nothing. Returns `px` unchanged at either end of the range.
face_next_px :: proc(f: ^Face, px, dir: int) -> int {
    was, _, _ := face_cell_at(f, tt.ScaleForPixelHeight(&f.info, f32(px)))
    for try := px + dir; face_px_ok(try); try += dir {
        if w, _, _ := face_cell_at(f, tt.ScaleForPixelHeight(&f.info, f32(try))); w != was {
            return try
        }
    }
    return px
}

face_has :: proc(f: ^Face, r: rune) -> bool {
    return tt.FindGlyphIndex(&f.info, r) != 0
}

// Rasterizes `r` into a cell-sized buffer the caller has already cleared. Baseline-aligned
// and horizontally centred, which is what keeps mixed faces on one line; a glyph too big for
// the cell is rescaled to fit, for itself alone.
face_bake :: proc(f: ^Face, r: rune, dst: []u8, cell_w, cell_h, baseline: int) -> bool {
    if !face_has(f, r) {
        return false
    }
    scale := f.scale
    x0, y0, x1, y1: i32
    tt.GetCodepointBitmapBox(&f.info, r, scale, scale, &x0, &y0, &x1, &y1)
    gw, gh := int(x1 - x0), int(y1 - y0)
    if gw <= 0 || gh <= 0 {
        return true // a blank glyph, space being the common one; the cleared cell is correct
    }

    if gw > cell_w || gh > cell_h {
        shrink := min(f32(cell_w) / f32(gw), f32(cell_h) / f32(gh))
        scale *= shrink
        tt.GetCodepointBitmapBox(&f.info, r, scale, scale, &x0, &y0, &x1, &y1)
        gw, gh = int(x1 - x0), int(y1 - y0)
        if gw <= 0 || gh <= 0 {
            return true
        }
    }

    tmp := make([]u8, gw * gh, context.temp_allocator)
    tt.MakeCodepointBitmap(&f.info, raw_data(tmp), i32(gw), i32(gh), i32(gw), scale, scale, r)

    ox := (cell_w - gw) / 2
    oy := baseline + int(y0)
    // A shrunk glyph has lost its relationship to the baseline, so centre it instead of
    // letting it hang below the cell.
    if oy < 0 || oy + gh > cell_h {
        oy = (cell_h - gh) / 2
    }

    for y in 0 ..< gh {
        dy := oy + y
        if dy < 0 || dy >= cell_h {
            continue
        }
        for x in 0 ..< gw {
            dx := ox + x
            if dx < 0 || dx >= cell_w {
                continue
            }
            dst[dy * cell_w + dx] = tmp[y * gw + x]
        }
    }
    return true
}

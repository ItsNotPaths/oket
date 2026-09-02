package gfx

import "core:encoding/endian"
import "core:mem"

// A uniform grid of glyph cells in one 8-bit coverage bitmap. Runes resolve in order:
// config font stack, bundled bitmap, tofu at slot 0. Face glyphs bake lazily; the bitmap
// bakes in full at startup so it is ready when everything else has gone wrong (§10).

Atlas :: struct {
    cell_w, cell_h: int,          // pixels per glyph
    baseline:       int,          // rows from the cell top down to the text baseline
    cols, rows:     int,          // glyph slots across the bitmap
    pixels:         []u8,         // coverage, (cols*cell_w) by (rows*cell_h)
    index:          map[rune]u16, // what has been resolved, from any source
    floor:          map[rune]u16, // the bundled bitmap's slots, consulted after the faces
    next:           u16,          // next free slot
    dirty:          [dynamic]u16, // baked since the painter last uploaded
    resized:        bool,         // the texture changed size; the painter must rebuild it
    faces:          []Face,       // config order; empty means the bitmap is all there is
    scratch:        []u8,         // one cell, staged here before blitting into the grid
}

ATLAS_COLS :: 32
ATLAS_MIN_ROWS :: 48

atlas_is_fallback :: proc(a: ^Atlas) -> bool {return len(a.faces) == 0}
atlas_width :: proc(a: ^Atlas) -> int {return a.cols * a.cell_w}
atlas_height :: proc(a: ^Atlas) -> int {return a.rows * a.cell_h}

atlas_origin :: proc(a: ^Atlas, slot: u16) -> (x, y: int) {
    return int(slot) % a.cols * a.cell_w, int(slot) / a.cols * a.cell_h
}

// Builds an atlas over `faces`, which it takes ownership of. The first face dictates the cell;
// with none, the bundled bitmap's own 8x16 does.
atlas_make :: proc(faces: []Face) -> (a: Atlas, ok: bool) {
    bm := bitmap_parse(FALLBACK_BLOB) or_return

    a.faces = faces
    if len(faces) > 0 {
        a.cell_w, a.cell_h, a.baseline = face_cell(&faces[0])
    } else {
        a.cell_w, a.cell_h = bm.cell_w, bm.cell_h
        a.baseline = bm.cell_h
    }

    a.cols = ATLAS_COLS
    a.rows = max(ATLAS_MIN_ROWS, (bm.count + a.cols - 1) / a.cols + 1)
    a.pixels = make([]u8, atlas_width(&a) * atlas_height(&a))
    a.scratch = make([]u8, a.cell_w * a.cell_h)

    bitmap_bake_all(&a, bm)
    return a, true
}

// The bundled bitmap alone: what the kernel draws with when no font stack loads.
atlas_fallback :: proc() -> (Atlas, bool) {
    return atlas_make(nil)
}

// The same faces at another size, keeping every file mapped. The cell moves, so every glyph
// baked into the old one is stale: the index is dropped and glyphs re-bake lazily on the next
// frame, exactly as they did on the first. False for a fallback atlas, whose bitmap is one
// fixed size and scales only in whole numbers (see painter_set_scale).
atlas_resize :: proc(a: ^Atlas, px: int) -> bool {
    if len(a.faces) == 0 {
        return false
    }
    bm := bitmap_parse(FALLBACK_BLOB) or_return
    for &f in a.faces {
        face_resize(&f, px)
    }
    a.cell_w, a.cell_h, a.baseline = face_cell(&a.faces[0])

    delete(a.pixels)
    delete(a.scratch)
    a.rows = max(ATLAS_MIN_ROWS, (bm.count + a.cols - 1) / a.cols + 1)
    a.pixels = make([]u8, atlas_width(a) * atlas_height(a))
    a.scratch = make([]u8, a.cell_w * a.cell_h)
    clear(&a.index)
    clear(&a.floor)
    clear(&a.dirty)
    a.resized = true // the texture changed size, so the painter uploads the whole of it

    bitmap_bake_all(a, bm) // it sets `next` and fills `floor`, which is why both are cleared
    return true
}

atlas_destroy :: proc(a: ^Atlas) {
    for &f in a.faces {
        face_close(&f)
    }
    delete(a.faces)
    delete(a.pixels)
    delete(a.scratch)
    delete(a.index)
    delete(a.floor)
    delete(a.dirty)
    a^ = {}
}

// What is resolved for `r` right now, baking nothing. 0 is the tofu box.
atlas_slot :: proc(a: ^Atlas, r: rune) -> u16 {
    if s, in_index := a.index[r]; in_index {
        return s
    }
    return a.floor[r] or_else 0
}

// The slot to draw `r` from, baking on first use. Faces win over the bundled bitmap:
// it is a floor, not a preference.
atlas_ensure :: proc(a: ^Atlas, r: rune) -> u16 {
    if s, done := a.index[r]; done {
        return s
    }
    for &f in a.faces {
        if !face_has(&f, r) {
            continue
        }
        slot, got := atlas_alloc(a)
        if !got {
            break // out of room; the floor below still beats a tofu
        }
        mem.zero_slice(a.scratch)
        if face_bake(&f, r, a.scratch, a.cell_w, a.cell_h, a.baseline) {
            atlas_blit(a, slot)
            a.index[r] = slot
            append(&a.dirty, slot)
            return slot
        }
        a.next -= 1 // the face said it had the glyph and produced nothing; take the slot back
    }
    // Cache the miss too, so the face walk happens once per rune rather than once per frame.
    a.index[r] = a.floor[r] or_else 0
    return a.index[r]
}

// ---------------------------------------------------------------------------
// Slots

@(private = "file")
atlas_alloc :: proc(a: ^Atlas) -> (u16, bool) {
    if int(a.next) >= a.cols * a.rows && !atlas_grow(a) {
        return 0, false
    }
    slot := a.next
    a.next += 1
    return slot, true
}

// Doubles rather than capping, so heavy CJK use never starts drawing tofu.
@(private = "file")
atlas_grow :: proc(a: ^Atlas) -> bool {
    rows := a.rows * 2
    pixels := make([]u8, atlas_width(a) * rows * a.cell_h)
    copy(pixels, a.pixels)
    delete(a.pixels)
    a.pixels = pixels
    a.rows = rows
    a.resized = true // a new texture, not a patch to the old one
    clear(&a.dirty)
    return true
}

@(private = "file")
atlas_blit :: proc(a: ^Atlas, slot: u16) {
    ox, oy := atlas_origin(a, slot)
    w := atlas_width(a)
    for y in 0 ..< a.cell_h {
        copy(a.pixels[(oy + y) * w + ox:][:a.cell_w], a.scratch[y * a.cell_w:][:a.cell_w])
    }
}

// ---------------------------------------------------------------------------
// The bundled bitmap

// Generated by tools/gen-atlas.py from Spleen 8x16 (see NOTICE); committed so a fresh
// clone builds without running the tool.
FALLBACK_BLOB := #load("fallback_atlas.bin")

@(private = "file")
HEADER :: 12 // magic, version, cell_w, cell_h, range_count, reserved

@(private = "file")
Bitmap :: struct {
    cell_w, cell_h: int,
    stride:         int, // bytes per glyph row
    count:          int, // glyphs, tofu included
    ranges:         [][2]rune,
    bits:           []u8,
}

@(private = "file")
bitmap_parse :: proc(b: []u8) -> (bm: Bitmap, ok: bool) {
    if len(b) < HEADER || string(b[:4]) != "OKAT" {
        return {}, false
    }
    if (endian.get_u16(b[4:], .Little) or_return) != 1 {
        return {}, false
    }
    bm.cell_w, bm.cell_h = int(b[6]), int(b[7])
    n := int(endian.get_u16(b[8:], .Little) or_return)
    if bm.cell_w == 0 || bm.cell_h == 0 || bm.cell_w % 8 != 0 {
        return {}, false
    }
    bm.stride = bm.cell_w / 8

    table := HEADER + n * 8
    if len(b) < table {
        return {}, false
    }
    bm.ranges = make([][2]rune, n)
    bm.count = 1 // slot 0 is the tofu
    for i in 0 ..< n {
        lo := endian.get_u32(b[HEADER + i * 8:], .Little) or_return
        hi := endian.get_u32(b[HEADER + i * 8 + 4:], .Little) or_return
        if hi < lo {
            delete(bm.ranges)
            return {}, false
        }
        bm.ranges[i] = {rune(lo), rune(hi)}
        bm.count += int(hi - lo) + 1
    }
    if len(b) < table + bm.count * bm.cell_h * bm.stride {
        delete(bm.ranges)
        return {}, false
    }
    bm.bits = b[table:]
    return bm, true
}

// Bakes every bundled glyph in blob order, so slot 0 really is the tofu. Integer scaling
// only: a whole-number multiple stays crisp, and leftover space becomes an even margin.
@(private = "file")
bitmap_bake_all :: proc(a: ^Atlas, bm: Bitmap) {
    defer delete(bm.ranges)

    sf := max(1, min(a.cell_w / bm.cell_w, a.cell_h / bm.cell_h))
    ox := (a.cell_w - bm.cell_w * sf) / 2
    oy := (a.cell_h - bm.cell_h * sf) / 2

    bake :: proc(a: ^Atlas, bm: Bitmap, g, sf, ox, oy: int) {
        src := g * bm.cell_h * bm.stride
        for y in 0 ..< bm.cell_h {
            row := src + y * bm.stride
            for x in 0 ..< bm.cell_w {
                if bm.bits[row + x / 8] >> uint(7 - x % 8) & 1 == 0 {
                    continue
                }
                for sy in 0 ..< sf {
                    dy := oy + y * sf + sy
                    if dy < 0 || dy >= a.cell_h {
                        continue
                    }
                    for sx in 0 ..< sf {
                        dx := ox + x * sf + sx
                        if dx >= 0 && dx < a.cell_w {
                            a.scratch[dy * a.cell_w + dx] = 255
                        }
                    }
                }
            }
        }
    }

    count := min(bm.count, a.cols * a.rows)
    for g in 0 ..< count {
        mem.zero_slice(a.scratch)
        bake(a, bm, g, sf, ox, oy)
        atlas_blit(a, u16(g))
    }
    a.next = u16(count)

    // Slot 0 is the tofu and belongs to no codepoint; the ranges start at slot 1.
    slot := u16(1)
    for r in bm.ranges {
        for cp := r[0]; cp <= r[1]; cp += 1 {
            a.floor[cp] = slot
            slot += 1
        }
    }
}

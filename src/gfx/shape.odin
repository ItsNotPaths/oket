package gfx

import "core:c"
import vmem "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"
import "../uni"

// HarfBuzz (vendored; IME.md §5): the one shaper. A run of one script goes to one face and
// comes back as glyph ids with the byte each came from. Positions do NOT come back: the cell
// grid decides where a glyph sits, which is the whole reason this note is short (§10).
foreign import hb "../../vendor/harfbuzz/libharfbuzz.a"

@(private = "file")
DIR_LTR :: 4 // hb_direction_t; RTL waits for §7's bidi, so nothing sets it yet
@(private = "file")
MEM_READONLY :: 1 // hb_memory_mode_t: the mapped file outlives every buffer built over it

// Off for Latin and for the punctuation runs where `->` and `>=` live: an operator is two
// characters and draws as two, per the user's call. `rlig` is NOT here — a required ligature
// is not decoration, and Arabic lam-alef is one.
@(private = "file")
NO_LIGATURES :: [4]Feature {
    {0x6C696761, 0, 0, max(u32)}, // liga, standard
    {0x636C6967, 0, 0, max(u32)}, // clig, contextual
    {0x646C6967, 0, 0, max(u32)}, // dlig, discretionary
    {0x63616C74, 0, 0, max(u32)}, // calt, contextual alternates: the programming-font door
}

@(private = "file")
Feature :: struct {
    tag:        u32,
    value:      u32,
    start, end: u32,
}

@(private = "file")
Glyph_Info :: struct {
    codepoint: u32,
    mask:      u32,
    cluster:   u32,
    var1, var2: u32,
}

@(default_calling_convention = "c", private = "file")
foreign hb {
    hb_blob_create :: proc(data: [^]u8, len: c.uint, mode: c.int, user: rawptr, destroy: rawptr) -> rawptr ---
    hb_blob_destroy :: proc(blob: rawptr) ---
    hb_face_create :: proc(blob: rawptr, index: c.uint) -> rawptr ---
    hb_face_destroy :: proc(face: rawptr) ---
    hb_font_create :: proc(face: rawptr) -> rawptr ---
    hb_font_destroy :: proc(font: rawptr) ---
    hb_buffer_create :: proc() -> rawptr ---
    hb_buffer_destroy :: proc(buf: rawptr) ---
    hb_buffer_clear_contents :: proc(buf: rawptr) ---
    hb_buffer_add_utf8 :: proc(buf: rawptr, text: [^]u8, len: c.int, offset: c.uint, item_len: c.int) ---
    hb_buffer_set_direction :: proc(buf: rawptr, dir: c.int) ---
    hb_buffer_set_script :: proc(buf: rawptr, script: u32) ---
    hb_shape :: proc(font: rawptr, buf: rawptr, features: [^]Feature, n: c.uint) ---
    hb_buffer_get_glyph_infos :: proc(buf: rawptr, n: ^c.uint) -> [^]Glyph_Info ---
}

// One run, shaped. `src` is parallel to `glyphs`: the byte offset in the run each glyph came
// from, which is how a caret at a byte finds its glyph and how a cluster finds its glyphs.
// Several glyphs share an offset when one character shaped into many; several offsets share a
// glyph when many characters shaped into one, and either way the array is the map (IME.md §5).
Shaped :: struct {
    glyphs: []Glyph,
    src:    []i32,
}

// The face the run's script wants: the first in the stack that covers the run's first rune.
// A run is one script by construction, so one face answers for all of it — picking per rune
// would hand HarfBuzz a different font mid-word and break every join in it.
shape_face :: proc(a: ^Atlas, r: rune) -> (u8, bool) {
    for &f, i in a.faces {
        if face_glyph(&f, r) != 0 {
            return u8(i), true
        }
    }
    return 0, false
}

// `text` is one script's bytes and `face` is the stack index that covers it. Glyphs come back
// in logical order: HarfBuzz is told left-to-right whatever the script, because reading order
// is §7's answer and not the shaper's.
shape_run :: proc(
    a: ^Atlas,
    face: u8,
    text: []u8,
    script: u32,
    alloc := context.temp_allocator,
) -> Shaped {
    if len(text) == 0 || int(face) >= len(a.faces) {
        return {}
    }
    f := &a.faces[face]
    if f.hb == nil {
        return {}
    }
    if a.buf == nil {
        a.buf = hb_buffer_create()
    }
    hb_buffer_clear_contents(a.buf)
    hb_buffer_add_utf8(a.buf, raw_data(text), c.int(len(text)), 0, c.int(len(text)))
    hb_buffer_set_direction(a.buf, DIR_LTR)
    hb_buffer_set_script(a.buf, script == uni.SCRIPT_UNKNOWN ? uni.SCRIPT_COMMON : script)
    if script == uni.SCRIPT_LATIN || script == uni.SCRIPT_COMMON || script == uni.SCRIPT_UNKNOWN {
        feats := NO_LIGATURES
        hb_shape(f.hb, a.buf, raw_data(feats[:]), len(feats))
    } else {
        hb_shape(f.hb, a.buf, nil, 0)
    }

    n: c.uint
    infos := hb_buffer_get_glyph_infos(a.buf, &n)
    out := Shaped {
        glyphs = make([]Glyph, int(n), alloc),
        src    = make([]i32, int(n), alloc),
    }
    for i in 0 ..< int(n) {
        out.glyphs[i] = Glyph{face, infos[i].codepoint}
        out.src[i] = i32(infos[i].cluster)
    }
    return out
}

// --- the face's shaper handle ---

// A HarfBuzz font over the same mapped bytes stbtt reads. Positions are never asked for, so
// the font keeps its default scale: only glyph ids and cluster numbers cross back.
@(private)
shape_open :: proc(f: ^Face) {
    blob := hb_blob_create(raw_data(f.data), c.uint(len(f.data)), MEM_READONLY, nil, nil)
    if blob == nil {
        return
    }
    defer hb_blob_destroy(blob)
    face := hb_face_create(blob, 0)
    if face == nil {
        return
    }
    defer hb_face_destroy(face)
    f.hb = hb_font_create(face)
}

@(private)
shape_close :: proc(f: ^Face) {
    if f.hb != nil {
        hb_font_destroy(f.hb)
        f.hb = nil
    }
}

@(private)
shape_buffer_close :: proc(a: ^Atlas) {
    if a.buf != nil {
        hb_buffer_destroy(a.buf)
        a.buf = nil
    }
}

// --- a whole row ---

// A screenful is 80 rows and a document is not, so what the cache holds is bounded.
SHAPE_CACHE_MAX :: 4096

// One line's bytes shaped, with `src` rebased onto the line. The face is chosen per RUN and
// never per character: hand HarfBuzz half a word in one font and half in another and every
// join in it breaks. A tab breaks a run and produces no glyph.
//
// The answer is cached on the atlas and owned by it, keyed on the row's BYTES: an edit reshapes
// that row and no other, a scroll reuses every row that stayed, and the faces moving drops the
// lot (IME.md §5).
shape_text :: proc(a: ^Atlas, src: []u8) -> Shaped {
    if a == nil || len(a.faces) == 0 || len(src) == 0 {
        return {}
    }
    if sh, simple := shape_ascii(a, src); simple {
        return sh
    }
    if hit, cached := a.shaped[string(src)]; cached {
        return hit
    }
    // Over the bound the whole cache goes, and a scroll that outruns it pays one screenful of
    // shaping. Sized to the bound on the first miss, or it rehashes its way there mid-scroll,
    // in the frames already paying for rows they have never seen.
    if len(a.shaped) >= SHAPE_CACHE_MAX {
        shape_forget(a)
    } else if cap(a.shaped) == 0 {
        reserve(&a.shaped, SHAPE_CACHE_MAX)
    }
    mem := vmem.arena_allocator(&a.shape_arena)
    glyphs := make([dynamic]Glyph, 0, len(src), mem)
    offs := make([dynamic]i32, 0, len(src), mem)
    for i := 0; i < len(src); {
        if src[i] == '\t' {
            i += 1
            continue
        }
        end, script, pick := script_run(src, i)
        if face, covered := shape_face(a, pick); covered {
            sh := shape_run(a, face, src[i:end], script)
            for gl, k in sh.glyphs {
                append(&glyphs, gl)
                append(&offs, sh.src[k] + i32(i))
            }
        }
        i = end
    }
    out := Shaped{glyphs[:], offs[:]}
    a.shaped[strings.clone(string(src), mem)] = out // the caller's bytes are a frame's, ours are not
    return out
}

// A row of ASCII shapes to one glyph per byte and nothing else: the decorative ligatures that
// could have joined two of them are off for Latin and Common (the user's call), and no ASCII
// character reorders, composes or takes a mark. So the answer is the face's own cmap, read out
// of a table filled when the face opened.
//
// Not an approximation, the same answer: `an_ascii_row_shapes_the_same_either_way` checks it
// against HarfBuzz character by character. It is here because a fast scroll draws 80 NEW rows
// a frame, which no cache can answer, and shaping them costs about 2 ms.
@(private = "file")
shape_ascii :: proc(a: ^Atlas, src: []u8) -> (Shaped, bool) {
    for b in src {
        if b >= 0x80 {
            return {}, false
        }
    }
    face, covered := shape_face(a, rune(src[0] == '\t' ? ' ' : src[0]))
    if !covered {
        return {}, false
    }
    f := &a.faces[face]
    // Frame memory, not the cache's: a row this cheap to answer is not worth remembering.
    glyphs := make([dynamic]Glyph, 0, len(src), context.temp_allocator)
    offs := make([dynamic]i32, 0, len(src), context.temp_allocator)
    for b, i in src {
        if b == '\t' {
            continue // a tab is blanks, and blanks are not a glyph
        }
        id := f.ascii[b]
        if id == 0 {
            return {}, false // a face missing an ASCII glyph is one the fallbacks must answer
        }
        append(&glyphs, Glyph{face, id})
        append(&offs, i32(i))
    }
    return Shaped{glyphs[:], offs[:]}, true
}

// Every key and every glyph list lives in one arena, so forgetting the lot is a pointer move
// rather than three deallocations a row. That matters: the drop lands mid-scroll, in a frame
// that is already shaping a screenful of rows it has never seen.
@(private)
shape_forget :: proc(a: ^Atlas) {
    clear(&a.shaped)
    vmem.arena_free_all(&a.shape_arena)
}

// The run starting at `off`: bytes of one script, up to the next tab. `pick` is the rune that
// chooses the face, and it is the first one that BELONGS to the run's script — a leading space
// or quote belongs to every script, so letting one choose would send a line of CJK to whichever
// face happened to have a space in it. A run that is punctuation to its end picks with the
// first rune it has.
@(private = "file")
script_run :: proc(src: []u8, off: int) -> (end: int, script: u32, pick: rune) {
    script = uni.SCRIPT_UNKNOWN
    for end = off; end < len(src) && src[end] != '\t'; {
        r, sz := utf8.decode_rune(src[end:])
        s := uni.script_join(script, uni.script_of(r))
        if script != uni.SCRIPT_UNKNOWN && s != script {
            break // a different script starts here, and it is a run of its own
        }
        if pick == 0 || (script == uni.SCRIPT_UNKNOWN && s != uni.SCRIPT_UNKNOWN) {
            pick = r
        }
        script = s
        end += max(sz, 1)
    }
    return
}

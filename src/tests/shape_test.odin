package tests

import "core:fmt"
import "core:testing"
import "../gfx"
import "../uni"

// The shaper is the one thing between a run of bytes and the glyphs that draw it. What it must
// answer is a glyph id per glyph and the byte each came from — never a position, because the
// cell grid decides those (IME.md §5).

// Latin shapes one glyph per character and the byte map is the identity. Trivial as typography
// and not as plumbing: it proves the archive links, the face opened a HarfBuzz font over the
// same bytes stbtt reads, and the cluster numbers come back as byte offsets into the run.
@(test)
shaping_maps_glyphs_back_to_bytes :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)

    face, covered := gfx.shape_face(&a, 'a')
    if !testing.expect(t, covered, "no face in the stack has 'a'") {
        return
    }
    sh := gfx.shape_run(&a, face, transmute([]u8)string("abc"), uni.script_of('a'))

    if !testing.expect_value(t, len(sh.glyphs), 3) {
        return
    }
    testing.expect_value(t, sh.src[0], i32(0))
    testing.expect_value(t, sh.src[1], i32(1))
    testing.expect_value(t, sh.src[2], i32(2))
    for r, i in "abc" {
        testing.expect_value(t, sh.glyphs[i].face, face)
        testing.expect_value(t, sh.glyphs[i].id, gfx.face_glyph(&a.faces[face], r))
    }
}

// A leading space belongs to every script and to none, so it must not be the rune that picks
// the face: a line of CJK that starts with an indent has to reach the CJK face and not whatever
// had a space in it. Before this rule, every indented non-Latin line drew .notdef.
@(test)
a_run_picks_the_face_its_script_needs :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)

    want, covered := gfx.shape_face(&a, '一')
    if !covered || want == 0 {
        return // one face covers everything on this machine; there is nothing to choose wrong
    }
    sh := gfx.shape_text(&a, transmute([]u8)string("  一二三"))
    if !testing.expect(t, len(sh.glyphs) > 0) {
        return
    }
    for gl, i in sh.glyphs {
        testing.expectf(t, gl.face == want, "glyph %d went to face %d, not %d", i, gl.face, want)
        testing.expectf(t, gl.id != 0, "glyph %d is .notdef; the face cannot draw it", i)
    }
}

// The point of the whole stage: a letter's glyph depends on its neighbours. Arabic beh between
// two alefs is its MEDIAL form, which is a different glyph from the one a cmap lookup answers.
// Skips where no face in the stack covers Arabic, because that is a machine's font list and
// not a bug in this.
@(test)
shaping_joins_arabic :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)

    BEH :: 'ب'
    face, covered := gfx.shape_face(&a, BEH)
    if !covered {
        return // no Arabic on this machine
    }
    isolated := gfx.face_glyph(&a.faces[face], BEH)
    sh := gfx.shape_run(&a, face, transmute([]u8)string("ابا"), uni.script_of(BEH))

    if !testing.expect_value(t, len(sh.glyphs), 3) {
        return
    }
    testing.expectf(t, sh.glyphs[1].id != isolated,
                    "beh between two alefs shaped to its isolated form (%d)", isolated)
    // Two bytes a character, so the middle glyph came from the middle one.
    testing.expect_value(t, sh.src[1], i32(2))
}

// The ASCII fast path skips HarfBuzz, so it has to agree with HarfBuzz exactly — this is what
// says it does. If a future change turns a ligature feature back on for Latin, or a face wants
// `ccmp` over ASCII, this fails and the fast path has to go (IME.md §5).
@(test)
an_ascii_row_shapes_the_same_either_way :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)

    face, covered := gfx.shape_face(&a, 'a')
    if !testing.expect(t, covered) {
        return
    }
    CASES :: [?]string {
        "a->b >= c != d <= e",
        "for (i = 0; i < n; ++i) { x[i] = *p++; }",
        "!\"#$%&'()*+,-./0123456789:;<=>?@",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`",
        "abcdefghijklmnopqrstuvwxyz{|}~",
        "fi fl ffi ffl -- --- <> </> |> =>",
        " ",
    }
    for text in CASES {
        row := transmute([]u8)text
        fast := gfx.shape_text(&a, row)
        slow := gfx.shape_run(&a, face, row, uni.SCRIPT_LATIN)

        if !testing.expectf(t, len(fast.glyphs) == len(slow.glyphs),
                            "%q: fast gave %d glyphs, HarfBuzz %d",
                            text, len(fast.glyphs), len(slow.glyphs)) {
            continue
        }
        for i in 0 ..< len(slow.glyphs) {
            testing.expectf(t, fast.glyphs[i] == slow.glyphs[i] && fast.src[i] == slow.src[i],
                            "%q glyph %d: fast %v@%d, HarfBuzz %v@%d",
                            text, i, fast.glyphs[i], fast.src[i], slow.glyphs[i], slow.src[i])
        }
    }
}

// A row that reached the shaper is REMEMBERED, because a screen redraws whole every frame and
// shaping a screenful costs about 2 ms. The proof is pointer identity: the second call hands
// back the same memory the first one built, so no clock is involved (IME.md §5).
@(test)
a_shaped_row_is_remembered :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)

    row := transmute([]u8)string("Привет мир")
    first := gfx.shape_text(&a, row)
    if !testing.expect(t, len(first.glyphs) > 0) {
        return
    }
    testing.expect_value(t, len(a.shaped), 1)

    again := gfx.shape_text(&a, row)
    testing.expect(t, raw_data(again.glyphs) == raw_data(first.glyphs), "the row was reshaped")
    testing.expect_value(t, len(a.shaped), 1)

    // The faces moving invalidates every glyph in it, so the cache goes with them.
    testing.expect(t, gfx.atlas_resize(&a, 32))
    testing.expect_value(t, len(a.shaped), 0)
}

// A fast scroll draws a screenful of rows the cache has never seen, every frame, which is the
// one workload no content-keyed cache can answer. What holds it up is that CODE never reaches
// HarfBuzz at all — and that is a structural claim, not a stopwatch: 24,000 rows of ASCII must
// leave the cache exactly as empty as they found it.
//
// Timing it would be the better gate and cannot be one: the runner is 32 threads deep, so a
// frame measured under it is contention. The real numbers live in IME.md §5, measured alone.
@(test)
a_random_scroll_does_not_stall :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)

    N :: 20000
    SCREEN :: 80
    FRAMES :: 300
    code := make([][]u8, N)
    text := make([][]u8, N)
    defer {
        for r in code {delete(r)}
        for r in text {delete(r)}
        delete(code);delete(text)
    }
    for i in 0 ..< N {
        code[i] = transmute([]u8)fmt.aprintf(
            "%5d    for cell in cell_of(row, a, tab) ..< min(cell_of(row, b, tab), w) {{", i,
        )
        text[i] = transmute([]u8)fmt.aprintf("%5d Привет мир, это строка русского текста %d", i, i)
    }

    seed: u64 = 12345
    scroll :: proc(a: ^gfx.Atlas, rows: [][]u8, seed: ^u64) {
        for _ in 0 ..< FRAMES {
            seed^ ~= seed^ << 13;seed^ ~= seed^ >> 7;seed^ ~= seed^ << 17
            top := int(seed^ % (N - SCREEN))
            for r in rows[top:][:SCREEN] {
                _ = gfx.shape_text(a, r)
            }
            free_all(context.temp_allocator)
        }
    }

    scroll(&a, code, &seed)
    testing.expect_value(t, len(a.shaped), 0)

    // Prose does reach the shaper, and this scrolls far enough to cross the cache's bound
    // several times over. What must hold is the bound itself.
    scroll(&a, text, &seed)
    testing.expect(t, len(a.shaped) <= gfx.SHAPE_CACHE_MAX, "the shape cache outgrew its bound")
}

// An operator is two characters and draws as two. This asks HARFBUZZ, not the ASCII fast path:
// the fast path cannot ligate whatever the features say, so testing through it would pass a
// font and a config that had turned `liga` back on. Silent on a face with no such ligature to
// form, which is the honest limit of it.
@(test)
an_operator_is_not_a_ligature :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)

    face, covered := gfx.shape_face(&a, '-')
    if !testing.expect(t, covered) {
        return
    }
    for text in ([?]string{"->", ">=", "!=", "<=", "=>", "|>", "fi", "ffl"}) {
        sh := gfx.shape_run(&a, face, transmute([]u8)text, uni.SCRIPT_COMMON)
        testing.expectf(t, len(sh.glyphs) == len(text),
                        "%q shaped into %d glyphs; a ligature formed", text, len(sh.glyphs))
    }
}

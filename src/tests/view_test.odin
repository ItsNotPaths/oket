package tests

import "core:strings"
import "core:testing"
import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"

// The gate for build order stage 3: the kernel draws a document from a descriptor, and a
// `<name>` hole reads a field the descriptor named. The screen is text, so this diffs in CI.

@(private = "file")
LISTING :: "src\tdir\t4\nmain.odin\tfile\t512\nREADME.md\tfile\t1024"

// name / kind / size, as the byte spans they occupy in each line of LISTING.
@(private = "file")
LISTING_FIELDS :: [?]desc.Field {
    {0, "name", 0, 3, ""},
    {0, "kind", 4, 7, ""},
    {0, "size", 8, 9, ""},
    {1, "name", 0, 9, ""},
    {1, "kind", 10, 14, ""},
    {1, "size", 15, 18, ""},
    {2, "name", 0, 9, ""},
    {2, "kind", 10, 14, ""},
    {2, "size", 15, 19, ""},
}

@(private = "file")
LISTING_COLUMNS :: [?]desc.Column{{"name", 12, .Left}, {"kind", 5, .Left}, {"size", 5, .Right}}

// Opens one document and hands back what a reader holds: the frozen text and the descriptor
// its generation named. Both are released by the returned proc.
@(private = "file")
opened :: proc(
    s: ^store.Store,
    text: string,
    d: desc.Descriptor,
) -> (
    snap: ^txt.Snapshot,
    dp: ^desc.Descriptor,
) {
    id := store.store_open(s, text)
    gen, _ := store.store_gen(s, id)
    published := desc.new_from(d)
    store.store_submit(s, id, gen, nil, published)
    desc.release(published) // the store holds its own reference now
    store.store_drain(s)
    return store.store_snapshot(s, id), store.store_descriptor(s, id)
}

// Into a grid the caller owns, for a test that asks about more than the snapshot text.
@(private = "file")
into :: proc(
    t: ^testing.T,
    g: ^gfx.Grid,
    text: string,
    d: desc.Descriptor,
    cols, rows: int,
    v := view.View{},
    atlas: ^gfx.Atlas = nil,
) {
    s: store.Store
    defer store.store_destroy(&s)
    snap, dp := opened(&s, text, d)
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    testing.expect(t, gfx.grid_init(g, cols, rows))
    view.draw(g, gfx.DEFAULT_THEME, &snap.text, dp, v, 0, 0, cols, rows, atlas = atlas)
}

@(private = "file")
drawn :: proc(
    t: ^testing.T,
    text: string,
    d: desc.Descriptor,
    cols, rows: int,
    v := view.View{},
) -> string {
    g: gfx.Grid
    defer gfx.grid_destroy(&g)
    into(t, &g, text, d, cols, rows, v)
    return gfx.grid_snapshot(&g)
}

// The stage gate. Nothing in the renderer knows this is a file listing: it pulls the columns'
// named fields out of each line and pads them, and the tabs in the source text never show.
@(test)
listing_renders_from_a_descriptor :: proc(t: ^testing.T) {
    columns := LISTING_COLUMNS
    fields := LISTING_FIELDS
    snap := drawn(t, LISTING, {columns = columns[:], fields = fields[:]}, 30, 4)
    defer delete(snap)

    testing.expect_value(
        t,
        snap,
        `src          dir       4
main.odin    file    512
README.md    file   1024
`,
    )
}

// `<path>` resolved as data, not as a callback into whoever drew the document (§5).
@(test)
field_resolves_from_the_descriptor :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    fields := LISTING_FIELDS
    snap, dp := opened(&s, LISTING, {fields = fields[:]})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    name, ok := view.field_text(&snap.text, dp, 1, "name")
    testing.expect(t, ok)
    testing.expect_value(t, name, "main.odin")

    size, size_ok := view.field_text(&snap.text, dp, 2, "size")
    testing.expect(t, size_ok)
    testing.expect_value(t, size, "1024")

    _, missing := view.field_text(&snap.text, dp, 1, "owner")
    testing.expect(t, !missing, "a field the descriptor never named must not resolve")
}

@(test)
line_numbers_count_absolute_and_relative :: proc(t: ^testing.T) {
    text :: "alpha\nbeta\ngamma\ndelta"

    abs := drawn(t, text, {numbers = .Absolute}, 12, 4)
    defer delete(abs)
    testing.expect_value(t, abs, `1 alpha
2 beta
3 gamma
4 delta`)

    rel := drawn(t, text, {numbers = .Relative}, 12, 4, view.View{point = {anchor = {line = 1}, head = {line = 1}}})
    defer delete(rel)
    testing.expect_value(t, rel, `1 alpha
2 beta
1 gamma
2 delta`)
}

@(test)
tabs_expand_to_the_tab_width :: proc(t: ^testing.T) {
    snap := drawn(t, "a\tb\nabc\td", {tab_width = 4}, 12, 2)
    defer delete(snap)
    testing.expect_value(t, snap, `a   b
abc d`)
}

// A row is the bytes it covers, so the paint and the measure cannot disagree about where one
// ends. Word wrap keeps the space on the leading row.
@(test)
wrap_splits_a_line_into_rows :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    snap, dp := opened(&s, "aaa bbb ccc", {wrap = .Char})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    by_char := view.rows(&snap.text, dp, 0, 7, 8)
    testing.expect_value(t, len(by_char), 2)
    testing.expect_value(t, by_char[0], view.Row{0, 0, 7, true, 0})
    testing.expect_value(t, by_char[1], view.Row{0, 7, 11, false, 0})

    word := desc.new_from({wrap = .Word})
    defer desc.release(word)
    by_word := view.rows(&snap.text, word, 0, 7, 8)
    testing.expect_value(t, len(by_word), 2)
    testing.expect_value(t, by_word[0], view.Row{0, 0, 4, true, 0})
    testing.expect_value(t, by_word[1], view.Row{0, 4, 11, false, 0})
}

// wrap: none is one row per line and the draw clips it, so a long line costs the viewport's
// width and not the line's.
@(test)
no_wrap_truncates_at_the_viewport :: proc(t: ^testing.T) {
    snap := drawn(t, "0123456789abcdef\nshort", {}, 8, 2)
    defer delete(snap)
    testing.expect_value(t, snap, `01234567
short`)
}

// The mouse's cell-to-byte walk shares `advance` with the paint, so a tab's cells all answer
// the tab and the blank right of a short line answers its end.
@(test)
locate_maps_cells_through_tabs :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    snap, dp := opened(&s, "a\tbc", {tab_width = 4})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    // cells: a=0, the tab runs 1..3, b=4, c=5
    p, _, ok := view.locate(&snap.text, dp, {}, 0, 0, 10, 2, 2, 0)
    testing.expect(t, ok)
    testing.expect_value(t, p, txt.Pos{0, 1}) // mid-tab is the tab's own byte

    p, _, ok = view.locate(&snap.text, dp, {}, 0, 0, 10, 2, 9, 0)
    testing.expect(t, ok)
    testing.expect_value(t, p, txt.Pos{0, 4}) // past the end is the end

    _, _, hit := view.locate(&snap.text, dp, {}, 0, 0, 10, 2, 10, 0)
    testing.expect(t, !hit, "a cell right of the rectangle is not in the document")
}

// The selected row is reverse video ACROSS THE ROW, its own text included. `run` writes whole
// cells, attributes and all, so a mark laid down before the columns are drawn survives only
// where no column reached — a row lit everywhere except the letters, which is what this catches.
@(test)
a_selected_row_is_marked_over_its_own_text :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    columns := LISTING_COLUMNS
    fields := LISTING_FIELDS
    snap, dp := opened(&s, LISTING, {columns = columns[:], fields = fields[:], selection = .Line})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 30, 3))
    defer gfx.grid_destroy(&g)
    view.draw(&g, gfx.DEFAULT_THEME, &snap.text, dp, {point = {anchor = {1, 0}, head = {1, 0}}}, 0, 0, 30, 3)

    lit, dark := 0, 0
    for x in 0 ..< 30 {
        if .Reverse in gfx.grid_at(&g, x, 1).attrs {
            lit += 1
        }
        if .Reverse in gfx.grid_at(&g, x, 0).attrs {
            dark += 1
        }
    }
    testing.expect_value(t, lit, 30) // the whole row, not the gaps between its columns
    testing.expect_value(t, dark, 0) // and only the row point is on
}

// The columnar arm walks the whole caret set too: each caret lights its own row.
@(test)
every_caret_lights_its_listing_row :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    columns := LISTING_COLUMNS
    fields := LISTING_FIELDS
    snap, dp := opened(&s, LISTING, {columns = columns[:], fields = fields[:], selection = .Line})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 30, 3))
    defer gfx.grid_destroy(&g)
    carets := [2]txt.Cursor{{anchor = {0, 0}, head = {0, 0}}, {anchor = {2, 0}, head = {2, 0}}}
    view.draw(&g, gfx.DEFAULT_THEME, &snap.text, dp, {}, 0, 0, 30, 3, carets = carets[:])

    for y in 0 ..< 3 {
        lit := 0
        for x in 0 ..< 30 {
            if .Reverse in gfx.grid_at(&g, x, y).attrs {
                lit += 1
            }
        }
        testing.expect_value(t, lit, y == 1 ? 0 : 30)
    }
}

// `[cursor] select` is how far the selection carries its swap. At 100 it is the reverse the
// caret gets; below it both sides move together, so the cell's own colours are still in the mix
// and a weaker reverse is what is left. The caret is never in it.
@(test)
a_selection_carries_its_swap_as_far_as_the_percent_says :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    snap, dp := opened(&s, "hello\nworld", {selection = .Char})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 10, 2))
    defer gfx.grid_destroy(&g)
    th := gfx.DEFAULT_THEME
    over := view.View{point = {anchor = {0, 0}, head = {0, 3}}}

    // Full: the painter's own swap, which is the attr and not a colour.
    view.draw(&g, th, &snap.text, dp, over, 0, 0, 10, 2, select = 100)
    testing.expect(t, .Reverse in gfx.grid_at(&g, 0, 0).attrs)
    testing.expect_value(t, gfx.grid_at(&g, 0, 0).fg, th[.Fg])

    // Half of the way there, written as colours: no attr, and the two sides have swapped half.
    view.draw(&g, th, &snap.text, dp, over, 0, 0, 10, 2, select = 50)
    cell := gfx.grid_at(&g, 0, 0)
    testing.expect(t, .Reverse not_in cell.attrs, "a percent left the painter's swap on too")
    testing.expect_value(t, cell.fg, th[.Fg] + (th[.Bg] - th[.Fg]) * 0.5)
    testing.expect_value(t, cell.bg, gfx.opaque(th[.Bg] + (th[.Fg] - th[.Bg]) * 0.5))

    // Past the selection, the row is untouched.
    testing.expect_value(t, gfx.grid_at(&g, 4, 0).fg, th[.Fg])

    // And the caret is a full swap whatever the percent says.
    caret := view.View{point = {anchor = {1, 0}, head = {1, 0}}}
    view.draw(&g, th, &snap.text, dp, caret, 0, 0, 10, 2, select = 50)
    testing.expect(t, .Reverse in gfx.grid_at(&g, 0, 1).attrs, "the percent reached the caret")
}

// A field's span is what it DRAWS and its value is what it ACTS on (desc.Field). A row showing
// a bare name while `<path>` hands on the whole of where it lives is the one thing a span alone
// could not say, and it is what makes a line a link.
@(test)
a_field_with_a_value_answers_with_it :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    fields := [?]desc.Field{{0, "name", 0, 3, ""}, {0, "path", 0, 3, "/tmp/src"}}
    snap, dp := opened(&s, "src", {fields = fields[:]})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    shown, _ := view.field_text(&snap.text, dp, 0, "name")
    testing.expect_value(t, shown, "src")
    acted, _ := view.field_text(&snap.text, dp, 0, "path")
    testing.expect_value(t, acted, "/tmp/src")
}

// --- the carets a draw can reach (view.onscreen) ---

// THE GATE, COUNTED. `:find` puts one caret per match, so the set is the DOCUMENT's size while
// the viewport is the SCREEN's — and the row loop asks every caret about every row. What the
// filter leaves is what the row loop walks, so counting it is counting the work.
@(test)
a_draw_only_walks_the_carets_on_screen :: proc(t: ^testing.T) {
    LINES :: 20_000
    ROWS :: 50

    s: store.Store
    defer store.store_destroy(&s)
    text := strings.repeat("ab\n", LINES, context.temp_allocator)
    snap, dp := opened(&s, text, {})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    carets := make([]txt.Cursor, LINES, context.temp_allocator)
    for i in 0 ..< LINES {
        carets[i] = {anchor = {i, 0}, head = {i, 1}} // one selection per line
    }

    rs := view.rows(&snap.text, dp, 0, 20, ROWS)
    testing.expect_value(t, len(rs), ROWS)
    on := view.onscreen(carets, view.row_span(rs))
    testing.expect_value(t, len(on), ROWS)
}

// A selection can cover the screen without either end being on it, and dropping one would leave
// a hole in the middle of a highlight. So the test is overlap, not containment.
@(test)
a_selection_across_the_screen_survives_the_filter :: proc(t: ^testing.T) {
    carets := [3]txt.Cursor {
        {anchor = {0, 0}, head = {0, 1}},     // above
        {anchor = {5, 0}, head = {40, 0}},    // straddling
        {anchor = {99, 0}, head = {99, 1}},   // below
    }
    on := view.onscreen(carets[:], 10, 20)
    testing.expect_value(t, len(on), 1)
    testing.expect_value(t, on[0].anchor.line, 5)
}

// Order is kept, and that is not a nicety: mark_row lights a row from the FIRST caret covering
// it and mark_point paints later carets over earlier ones. The set is unsorted by design
// (txt/cursor.odin), so a filter that reordered would move pixels.
@(test)
the_filter_keeps_the_set_in_the_order_it_arrived :: proc(t: ^testing.T) {
    carets := [3]txt.Cursor {
        {anchor = {8, 0}, head = {8, 1}},
        {anchor = {2, 0}, head = {2, 1}},
        {anchor = {5, 0}, head = {5, 1}},
    }
    on := view.onscreen(carets[:], 0, 10)
    testing.expect_value(t, len(on), 3)
    testing.expect_value(t, on[0].anchor.line, 8)
    testing.expect_value(t, on[1].anchor.line, 2)
    testing.expect_value(t, on[2].anchor.line, 5)
}

// The same set through a real draw: an unsorted pair over a listing lights both rows and no
// third one. The filter runs inside draw, so this is what says it kept the marking honest.
@(test)
an_unsorted_caret_set_lights_the_rows_it_names :: proc(t: ^testing.T) {
    s: store.Store
    defer store.store_destroy(&s)
    columns := LISTING_COLUMNS
    fields := LISTING_FIELDS
    snap, dp := opened(&s, LISTING, {columns = columns[:], fields = fields[:], selection = .Line})
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 30, 3))
    defer gfx.grid_destroy(&g)
    // Row 2 named before row 0, and a coincident pair on row 2 for good measure.
    carets := [3]txt.Cursor {
        {anchor = {2, 0}, head = {2, 0}},
        {anchor = {0, 0}, head = {0, 0}},
        {anchor = {2, 0}, head = {2, 0}},
    }
    view.draw(&g, gfx.DEFAULT_THEME, &snap.text, dp, {}, 0, 0, 30, 3, carets = carets[:])

    for y in 0 ..< 3 {
        lit := 0
        for x in 0 ..< 30 {
            if .Reverse in gfx.grid_at(&g, x, y).attrs {
                lit += 1
            }
        }
        testing.expect_value(t, lit, y == 1 ? 0 : 30)
    }
}

// A combining mark owns no column, so it cannot be a cell. It rides over the cell its BASE
// went into, which is the wide rune's first column and not its continuation (IME.md §6).
@(test)
a_combining_mark_rides_over_its_base_cell :: proc(t: ^testing.T) {
    g: gfx.Grid
    defer gfx.grid_destroy(&g)
    into(t, &g, "e\u0301x\na\u4E00\u0301", {}, 8, 2)

    // The cells are untouched: the mark took no column from the text beside it.
    snap := gfx.grid_snapshot(&g)
    defer delete(snap)
    testing.expect_value(t, snap, "ex\na\u4E00")

    if !testing.expect_value(t, len(g.marks), 2) {
        return
    }
    testing.expect_value(t, g.marks[0].cell, i32(0))
    testing.expect_value(t, g.marks[0].r, '\u0301')
    testing.expect_value(t, g.marks[1].cell, i32(g.cols + 1))
    testing.expect_value(t, g.marks[1].r, '\u0301')
}


// The shaper reaches the screen: a drawn cell carries the glyph HarfBuzz chose, and the cell
// still carries the base RUNE beside it — which is the invariant every screen test rests on,
// because grid_snapshot reads runes and knows nothing about glyphs (IME.md §6).
@(test)
a_drawn_row_carries_the_shapers_glyphs :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)

    g: gfx.Grid
    defer gfx.grid_destroy(&g)
    into(t, &g, "abc", {}, 8, 1, atlas = &a)

    snap := gfx.grid_snapshot(&g)
    defer delete(snap)
    testing.expect_value(t, snap, "abc")

    face, _ := gfx.shape_face(&a, 'a')
    for r, i in "abc" {
        cell := gfx.grid_at(&g, i, 0)
        testing.expect_value(t, cell.r, r)
        want, _ := gfx.atlas_ensure_glyph(&a, gfx.Glyph{face, gfx.face_glyph(&a.faces[face], r)})
        testing.expectf(t, cell.slot == want, "cell %d drew slot %d, not %d", i, cell.slot, want)
    }
}

// The same, for a row that really does go through HarfBuzz: ASCII takes the fast path, so a
// Latin row proves the plumbing and not the shaper. A wide cluster also has to leave its
// continuation cell alone, which is where a slot written one column too far would show.
@(test)
a_shaped_row_reaches_the_grid :: proc(t: ^testing.T) {
    a, ok := stacked(t, 24)
    if !ok {
        return
    }
    defer gfx.atlas_destroy(&a)
    if _, covered := gfx.shape_face(&a, '一'); !covered {
        return
    }

    g: gfx.Grid
    defer gfx.grid_destroy(&g)
    into(t, &g, "一二", {}, 8, 1, atlas = &a)

    testing.expect_value(t, len(a.shaped), 1) // it went through the shaper, not the fast path
    col := 0
    for r in "一二" {
        cell := gfx.grid_at(&g, col, 0)
        testing.expect_value(t, cell.r, r)
        testing.expectf(t, cell.slot != 0, "the wide cluster at %d drew from its rune", col)
        testing.expect_value(t, gfx.grid_at(&g, col + 1, 0).slot, u16(0))
        col += 2
    }
}


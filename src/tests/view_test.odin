package tests

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
    {0, "name", 0, 3},
    {0, "kind", 4, 7},
    {0, "size", 8, 9},
    {1, "name", 0, 9},
    {1, "kind", 10, 14},
    {1, "size", 15, 18},
    {2, "name", 0, 9},
    {2, "kind", 10, 14},
    {2, "size", 15, 19},
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

@(private = "file")
drawn :: proc(
    t: ^testing.T,
    text: string,
    d: desc.Descriptor,
    cols, rows: int,
    v := view.View{},
) -> string {
    s: store.Store
    defer store.store_destroy(&s)
    snap, dp := opened(&s, text, d)
    defer txt.snapshot_release(snap)
    defer desc.release(dp)

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, cols, rows))
    defer gfx.grid_destroy(&g)

    view.draw(&g, gfx.DEFAULT_THEME, &snap.text, dp, v, 0, 0, cols, rows)
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

    rel := drawn(t, text, {numbers = .Relative}, 12, 4, view.View{cursor = 1})
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
    testing.expect_value(t, by_char[0], view.Row{0, 0, 7, true})
    testing.expect_value(t, by_char[1], view.Row{0, 7, 11, false})

    word := desc.new_from({wrap = .Word})
    defer desc.release(word)
    by_word := view.rows(&snap.text, word, 0, 7, 8)
    testing.expect_value(t, len(by_word), 2)
    testing.expect_value(t, by_word[0], view.Row{0, 0, 4, true})
    testing.expect_value(t, by_word[1], view.Row{0, 4, 11, false})
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

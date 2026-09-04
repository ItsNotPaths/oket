package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../input"
import "../store"
import "../txt"
import app "../oket"

// VIEWS.md stage 3's gate: the placement verbs of §4, motion over the whole set, and the two
// ends that are not `txt`'s — alt+click, which needs the mouse's press-then-chord order, and
// Escape, which is not a row.
//
// A caret is PLACED, not walked to. Nothing here arms a mode or holds a prefix, and that is
// what these tests are really guarding: every verb says where the next caret goes.

@(private = "file")
mk :: proc(s: string, at := txt.Pos{}) -> txt.Doc {
    d: txt.Doc
    txt.doc_init(&d)
    txt.doc_set_text(&d, s)
    txt.doc_reset_cursor(&d, at)
    return d
}

@(private = "file")
text :: proc(d: ^txt.Doc) -> string {
    return txt.doc_string(d, context.temp_allocator)
}

// --- the column ---

// Three carets stacked in a column all take the rune, which is the whole of what multi-cursor
// is for. Two verbs and a keystroke, with no mode in between.
@(test)
three_carets_in_a_column_take_a_rune :: proc(t: ^testing.T) {
    d := mk("ab\ncd\nef")
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_add_cursor_line(&d, +1))
    testing.expect(t, txt.doc_add_cursor_line(&d, +1))
    testing.expect_value(t, len(d.cursors), 3)

    testing.expect(t, txt.doc_insert_rune(&d, 'X'))
    testing.expect_value(t, text(&d), "Xab\nXcd\nXef")
}

// The column follows the goal column, not the byte one: a short line in the middle must not
// drag the caret below it back to where the short line ended.
@(test)
a_column_keeps_its_goal_over_a_short_line :: proc(t: ^testing.T) {
    d := mk("abcd\nx\nefgh", {0, 3})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_add_cursor_line(&d, +1))
    testing.expect(t, txt.doc_add_cursor_line(&d, +1))
    testing.expect_value(t, d.cursors[1].head, txt.Pos{1, 1}) // clamped to the short line
    testing.expect_value(t, d.cursors[2].head, txt.Pos{2, 3}) // and back out on the long one
}

// Off either end there is no line to place one on, and the set is left as it was.
@(test)
a_column_stops_at_the_edges :: proc(t: ^testing.T) {
    d := mk("only")
    defer txt.doc_destroy(&d)

    testing.expect(t, !txt.doc_add_cursor_line(&d, -1))
    testing.expect(t, !txt.doc_add_cursor_line(&d, +1))
    testing.expect_value(t, len(d.cursors), 1)
}

// --- motion is what the set does ---

// The arrows move every caret, so the column stays a column. Single cursor is N == 1, which is
// why no older motion test moved for this.
@(test)
arrows_move_the_whole_set :: proc(t: ^testing.T) {
    d := mk("abc\ndef")
    defer txt.doc_destroy(&d)
    testing.expect(t, txt.doc_add_cursor_line(&d, +1))

    txt.doc_move(&d, .Right)
    txt.doc_move(&d, .Right)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 2})
    testing.expect_value(t, d.cursors[1].head, txt.Pos{1, 2})

    // Shift extends every one of them.
    txt.doc_move(&d, .End, true)
    testing.expect_value(t, d.cursors[0].anchor, txt.Pos{0, 2})
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 3})
}

// Two carets that land on one position name one range, and doc_merge_cursors fuses them. The
// count drops, which is right: an edit applied twice to one range is the bug the merge exists
// for. Here the leading caret runs out of document and the one behind catches it up.
@(test)
carets_that_meet_fuse :: proc(t: ^testing.T) {
    d := mk("ab", {0, 0})
    defer txt.doc_destroy(&d)
    txt.doc_add_cursor(&d, {0, 1})
    testing.expect_value(t, len(d.cursors), 2)

    txt.doc_move(&d, .Right)
    testing.expect_value(t, len(d.cursors), 2)
    txt.doc_move(&d, .Right)
    testing.expect_value(t, len(d.cursors), 1)
}

// --- the match verbs ---

// alt+d is two halves under one key: the first press decides what to look for, and only the
// next one grows the set. Pressing it once must never add a caret somewhere you have not read.
@(test)
add_next_match_seeds_then_grows :: proc(t: ^testing.T) {
    d := mk("foo bar\nfoo baz\nfoo qux", {0, 1})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_add_next_match(&d))
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].anchor, txt.Pos{0, 0})
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 3})

    testing.expect(t, txt.doc_add_next_match(&d))
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.cursors[1].anchor, txt.Pos{1, 0})

    testing.expect(t, txt.doc_add_next_match(&d))
    testing.expect_value(t, len(d.cursors), 3)

    // Every occurrence is taken, so the wrap finds one that is already a caret and stops.
    testing.expect(t, !txt.doc_add_next_match(&d))
    testing.expect_value(t, len(d.cursors), 3)

    testing.expect(t, txt.doc_insert_rune(&d, 'X'))
    testing.expect_value(t, text(&d), "X bar\nX baz\nX qux")
}

// alt+shift+d seeds the same way and then takes the lot, the primary's own occurrence among
// them rather than beside it.
@(test)
add_all_matches_takes_every_one :: proc(t: ^testing.T) {
    d := mk("foo bar foo\nfoo", {0, 1})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_add_all_matches(&d)) // the seed
    testing.expect(t, txt.doc_add_all_matches(&d))
    testing.expect_value(t, len(d.cursors), 3)

    testing.expect(t, txt.doc_insert_rune(&d, 'X'))
    testing.expect_value(t, text(&d), "X bar X\nX")
}

// A seed selected right-to-left is the same occurrence however the drag that made it ran, so
// the wrap stops on it instead of doubling a caret over the primary's own word.
@(test)
a_reversed_seed_is_still_taken :: proc(t: ^testing.T) {
    d := mk("foo foo")
    defer txt.doc_destroy(&d)
    txt.doc_select_span(&d, {0, 3}, {0, 0})

    testing.expect(t, txt.doc_add_next_match(&d))
    testing.expect(t, !txt.doc_add_next_match(&d))
    testing.expect_value(t, len(d.cursors), 2)
}

// A selection across a line break has no occurrences to find: every literal search in the
// kernel is line by line, and answering anyway would mean a second search engine.
@(test)
a_match_across_a_break_finds_nothing :: proc(t: ^testing.T) {
    d := mk("ab\nab\nab")
    defer txt.doc_destroy(&d)
    txt.doc_select_span(&d, {0, 0}, {1, 2})

    testing.expect(t, !txt.doc_add_next_match(&d))
    testing.expect(t, !txt.doc_add_all_matches(&d))
    testing.expect_value(t, len(d.cursors), 1)
}

// --- split ---

// The default family: one SELECTION per line, over what the old one covered there. Sublime,
// Kakoune and Helix all answer this way, and `[cursor] split` is what picks the other.
@(test)
split_lines_gives_one_selection_per_line :: proc(t: ^testing.T) {
    d := mk("aa\nbbb\ncccc\ndd")
    defer txt.doc_destroy(&d)
    txt.doc_select_span(&d, {0, 1}, {3, 0})

    testing.expect(t, txt.doc_split_lines(&d))
    testing.expect_value(t, len(d.cursors), 3)
    testing.expect_value(t, d.cursors[0].anchor, txt.Pos{0, 1}) // where the old one started
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 2})
    testing.expect_value(t, d.cursors[1].anchor, txt.Pos{1, 0})
    testing.expect_value(t, d.cursors[1].head, txt.Pos{1, 3})
    testing.expect_value(t, d.cursors[2].head, txt.Pos{2, 4})

    testing.expect(t, txt.doc_insert_rune(&d, ';'))
    testing.expect_value(t, text(&d), "a;\n;\n;\ndd")
}

// `[cursor] split = carets` is the other one: a caret at each line's end and the selection gone,
// which is what VS Code and JetBrains do.
@(test)
split_lines_into_carets_drops_the_selection :: proc(t: ^testing.T) {
    d := mk("aa\nbbb\ncccc\ndd")
    defer txt.doc_destroy(&d)
    txt.doc_select_span(&d, {0, 0}, {3, 0})

    testing.expect(t, txt.doc_split_lines(&d, .Carets))
    testing.expect_value(t, len(d.cursors), 3)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 2})
    testing.expect_value(t, d.cursors[1].head, txt.Pos{1, 3})
    testing.expect_value(t, d.cursors[2].head, txt.Pos{2, 4})
    testing.expect(t, !txt.cursor_has_selection(d.cursors[0]))

    testing.expect(t, txt.doc_insert_rune(&d, ';'))
    testing.expect_value(t, text(&d), "aa;\nbbb;\ncccc;\ndd")
}

// One line is where the two families visibly disagree, so it is where the config has to bite.
@(test)
split_lines_answers_one_line_by_the_family :: proc(t: ^testing.T) {
    d := mk("aabbcc")
    defer txt.doc_destroy(&d)
    txt.doc_select_span(&d, {0, 1}, {0, 4})

    testing.expect(t, txt.doc_split_lines(&d))
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].anchor, txt.Pos{0, 1})
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 4})

    testing.expect(t, txt.doc_split_lines(&d, .Carets))
    testing.expect_value(t, d.cursors[0].anchor, txt.Pos{0, 4})
    testing.expect_value(t, d.cursors[0].head, txt.Pos{0, 4})
}

// Nothing selected is nothing to split, and a caret that was left where it was is not a verb
// that quietly moved it.
@(test)
split_lines_leaves_a_bare_caret_alone :: proc(t: ^testing.T) {
    d := mk("aa\nbb", {1, 1})
    defer txt.doc_destroy(&d)

    testing.expect(t, !txt.doc_split_lines(&d))
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].head, txt.Pos{1, 1})
}

// --- the two that are the kernel's ---

@(private = "file")
notes_app :: proc(t: ^testing.T, name, body: string) -> (a: app.App, ok: bool) {
    a = bare_app(50, 10) or_return
    app.ring_add(&a, scratch_doc(&a, name, body))
    app.surface_draw(&a) // the body rectangle a click is placed against
    return a, true
}

@(private = "file")
focused_doc :: proc(a: ^app.App) -> ^txt.Doc {
    return store.store_doc(&a.docs, app.active(a).doc)
}

// The press half of a button chord, then the release half, the way input.odin drives them.
@(private = "file")
click_at :: proc(a: ^app.App, mods: input.Mods, cx, cy: int) {
    app.point_press(a, .Click, mods, cx, cy)
    input.mouse_press(&a.mouse, .Click, cx, cy)
    app.handle_chord(a, {input.mouse_code(.Click), mods, 0})
}

// alt+click adds a caret and a plain click puts the trail down. The kernel moves point before it
// dispatches a button chord (§8), so the row has to be able to say `not for me` — otherwise the
// move takes down the very carets cursor.add exists to add to.
@(test)
alt_click_adds_a_caret :: proc(t: ^testing.T) {
    a, ok := notes_app(t, "note", "alpha\nbeta\ngamma")
    if !ok {
        return
    }
    defer close_app(&a)

    doc := focused_doc(&a)
    click_at(&a, {}, 1, 0)
    testing.expect_value(t, len(doc.cursors), 1)
    testing.expect_value(t, doc.cursors[0].head.line, 0)

    click_at(&a, {.Alt}, 1, 2)
    testing.expect_value(t, len(doc.cursors), 2)
    testing.expect_value(t, doc.cursors[0].head.line, 0)
    testing.expect_value(t, doc.cursors[doc.primary].head.line, 2)

    // And a plain one is still the way out of a trail that needs no key at all.
    click_at(&a, {}, 1, 1)
    testing.expect_value(t, len(doc.cursors), 1)
    testing.expect_value(t, doc.cursors[0].head.line, 1)
}

// Escape puts the trail down ahead of every row that claims the key, and only while one is up:
// with a single caret it falls through to what it always meant.
@(test)
esc_puts_the_trail_down_before_it_quits :: proc(t: ^testing.T) {
    a, ok := notes_app(t, "note", "aa\nbb\ncc")
    if !ok {
        return
    }
    defer close_app(&a)

    doc := focused_doc(&a)
    testing.expect(t, txt.doc_add_cursor_line(doc, +1))
    testing.expect(t, txt.doc_add_cursor_line(doc, +1))

    // The bar says a trail is up and how to put it down, because no row does.
    testing.expect(t, strings.contains(app.bar_text(&a), "3 carets, esc puts them down"))

    app.handle_chord(&a, chord("ESC"))
    testing.expect_value(t, len(doc.cursors), 1)
    testing.expect(t, !a.quit, "escape put the trail down, it did not fall through to quit")

    app.handle_chord(&a, chord("ESC"))
    testing.expect(t, a.quit, "with one caret escape means what it always meant")
}

// The keyboard rows, end to end and through the bind table, so the chords in binds_default are
// the ones the verbs answer to.
@(test)
the_cursor_rows_reach_their_verbs :: proc(t: ^testing.T) {
    a, ok := notes_app(t, "note", "foo\nfoo\nfoo")
    if !ok {
        return
    }
    defer close_app(&a)

    doc := focused_doc(&a)
    app.point_place(&a, 1, 1) // the middle line, so both directions have somewhere to go
    app.handle_chord(&a, chord("UP", {.Ctrl, .Alt}))
    testing.expect_value(t, len(doc.cursors), 2)
    app.handle_chord(&a, chord("DOWN", {.Ctrl, .Alt}))
    testing.expect_value(t, len(doc.cursors), 3)

    app.handle_chord(&a, chord("ESC"))
    testing.expect_value(t, len(doc.cursors), 1)
    app.handle_chord(&a, chord("AC03", {.Alt})) // alt+d seeds
    app.handle_chord(&a, chord("AC03", {.Alt, .Shift})) // alt+shift+d takes the lot
    testing.expect_value(t, len(doc.cursors), 3)
}

// The verb keeps no default chord, so a row is how it gets one, and `[cursor] split` is what
// decides what it leaves on each line. Both halves of that, through the files that carry them.
@(test)
a_config_line_picks_what_a_split_leaves :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-split-config")
    if !made {
        return
    }
    defer os.remove_all(dir)
    a, ok := notes_app(t, "note", "aa\nbb\ncc")
    if !ok {
        return
    }
    defer close_app(&a)
    a.home = strings.clone(dir)
    defer delete(a.home)

    path, _ := filepath.join({dir, app.CONFIG_NAME}, context.temp_allocator)
    body := "[cursor]\nsplit = carets\n"
    testing.expect_value(t, os.write_entire_file(path, transmute([]u8)body), nil)
    app.config_load(&a)
    testing.expect_value(t, a.config.split, txt.Split.Carets)

    app.binds_parse(&a, "[text]\nalt+@AC02 = cursor.split_lines\n", "binds.conf")
    doc := focused_doc(&a)
    txt.doc_select_span(doc, {0, 0}, {2, 0})
    app.handle_chord(&a, chord("AC02", {.Alt}))
    testing.expect_value(t, len(doc.cursors), 2)
    testing.expect(t, !txt.cursor_has_selection(doc.cursors[0]), "the file said carets")
}

// describe answers for every cursor row it is asked about, and for alt+click it must NOT say
// `moves point, then`: that chord is the one whose point move the kernel skips.
@(test)
describe_answers_the_cursor_rows :: proc(t: ^testing.T) {
    a, dir, ok := listing_app(t, "oket-cursor-describe")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    Row :: struct {
        chord: input.Chord,
        cmd:   input.Command,
    }
    rows := [?]Row {
        {chord("DOWN", {.Ctrl, .Alt}), .Cursor_Add_Below},
        {chord("UP", {.Ctrl, .Alt}), .Cursor_Add_Above},
        {chord("AC03", {.Alt}), .Cursor_Add_Next},
        {chord("AC03", {.Alt, .Shift}), .Cursor_Add_All},
        {{input.mouse_code(.Click), {.Alt}, 0}, .Cursor_Add},
    }
    for row in rows {
        answer := input.describe_chord(a.binds[:], row.chord, .Surface, nil)
        defer delete(answer)
        info := input.COMMANDS[row.cmd]
        testing.expectf(t, strings.contains(answer, info.name), "%s: %s", info.name, answer)
        testing.expectf(t, strings.contains(answer, info.doc), "%s: %s", info.name, answer)
        testing.expectf(t, !strings.contains(answer, "moves point, then"),
                        "%s: the press skips the kernel's point move: %s", info.name, answer)
    }
}

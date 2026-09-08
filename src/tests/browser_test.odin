package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../desc"
import "../gfx"
import "../input"
import "../store"
import "../txt"
import "../view"
import app "../oket"

// Stage 10's gate (§13): a file listing navigates and opens, and `enter` is a binds.conf row
// rather than a callback. What it now also has to answer is whether one document can be `ls -la`
// output AND a text field — every row a link, the caret pinned to the end of a name, and typing
// a rename — because that is what a file browser is once it stops being a widget.
//
// The subject is plugins/browser, built by plugins/stage.sh. plugins/edit is loaded beside it,
// because "opens" means a row reaches a DIFFERENT plugin through the kernel's own `:open`.

// The fixed prefix every row draws before its name: mode, size, date. The plugin's layout, and
// asserted here so a change to it fails loudly rather than shifting every column assertion
// below. A subtree opened in place indents one level past it.
@(private = "file")
PREFIX :: 36
@(private = "file")
NESTED :: PREFIX + 2

// tree/
//   sub/
//     deep.txt
//   top.txt
@(private = "file")
tree_app :: proc(t: ^testing.T, name: string) -> (a: app.App, root: string, ok: bool) {
    a = plug_app(t, name, "plugins/browser", "plugins/edit") or_return
    app.plug_init(&a)
    for plugin in ([?]string{"browser", "edit"}) {
        if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, plugin)), a.message) {
            close_plug_app(&a)
            return {}, "", false
        }
    }
    root, _ = filepath.join({home_dir(a.home), "tree"}, context.temp_allocator)
    sub, _ := filepath.join({root, "sub"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(sub)
    for f in ([?][2]string{{root, "top.txt"}, {sub, "deep.txt"}}) {
        path, _ := filepath.join({f[0], f[1]}, context.temp_allocator)
        _ = os.write_entire_file(path, transmute([]u8)string("xyz"))
    }

    // `files`, not a name of its own: the kernel aims a directory at whoever registers that
    // kind, so the browser IS what a directory opens as, in the lane alt+f already goes to.
    id, opened := app.files_open(&a, root)
    if !testing.expect(t, opened, a.message) {
        close_plug_app(&a)
        return {}, "", false
    }
    app.ring_add(&a, id)
    app.surface_draw(&a) // the body rectangle, so a click and a viewport have somewhere to land
    return a, root, true
}

@(private = "file")
reading :: proc(a: ^app.App) -> (^txt.Snapshot, ^desc.Descriptor) {
    id := app.ring_focused(a).doc
    return store.store_snapshot(&a.docs, id), store.store_descriptor(&a.docs, id)
}

@(private = "file")
doc_of :: proc(a: ^app.App) -> ^txt.Doc {
    return store.store_doc(&a.docs, app.ring_focused(a).doc)
}

@(private = "file")
line_text :: proc(s: ^txt.Snapshot, line: int, alloc := context.temp_allocator) -> string {
    return string(txt.text_line(&s.text, line, alloc))
}

// The name one row draws, which is the only part of it anything here asserts by value: the
// mode, the size and the date are the platter's and change under the test.
@(private = "file")
name_of :: proc(a: ^app.App, line: int) -> string {
    snap, d := reading(a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    out, _ := view.field_text(&snap.text, d, line, "name", alloc = context.temp_allocator)
    return strings.clone(out, context.temp_allocator)
}

// Point onto a row the way every key that moves does: at the end of its name, ready to type.
@(private = "file")
go_row :: proc(a: ^app.App, line: int) {
    txt.doc_set_head(doc_of(a), {line, 0}, false)
    app.point_sync(a)
    app.cl_exec(a, ":br.snap")
}

// The shape of the thing: `ls -la` rows, and a LINK over the name of each — the span is what it
// draws and the value is the path it acts on. No columns and no depth, because an `ls -la` line
// puts its name last and both of those would indent the mode bits along with it.
@(test)
a_row_is_ls_la_with_a_link_on_the_name :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-shape")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)

    kind, _ := app.kind_named(&a, "files")
    testing.expect_value(t, d.kind, kind)
    testing.expect_value(t, d.ctx, input.Bind_Ctx.Surface)
    testing.expect_value(t, d.selection, desc.Selection.Char) // a caret in a name, not a row
    testing.expect(t, d.editable, "a listing you cannot type into")
    testing.expect_value(t, len(d.columns), 0)
    testing.expect_value(t, len(d.depth), 0)

    // `..` first, whatever the directory holds and wherever it is, then the entries with
    // directories before files. A directory draws a trailing slash and its NAME does not carry
    // one: the slash is punctuation, and a caret at the end of a name lands before it.
    testing.expect_value(t, txt.text_line_count(snap), 3)
    for want, line in ([?]string{"..", "sub", "top.txt"}) {
        testing.expect_value(t, name_of(&a, line), want)
    }
    testing.expect(t, strings.has_suffix(line_text(snap, 0), "../"), line_text(snap, 0))
    testing.expect(t, strings.has_prefix(line_text(snap, 2), "-rw-"), line_text(snap, 2))
    testing.expect(t, strings.has_suffix(line_text(snap, 1), "sub/"), line_text(snap, 1))

    // Every name starts at the same column, so a rename never moves what is left of it, and a
    // child of the root sits one indent past that.
    lo, hi, _ := desc.field_span(d, 2, "name")
    testing.expect_value(t, lo, PREFIX)
    testing.expect_value(t, hi, PREFIX + len("top.txt"))
    mode_lo, mode_hi, _ := desc.field_span(d, 2, "mode")
    testing.expect_value(t, mode_lo, 0)
    testing.expect_value(t, mode_hi, 10)
    size, _ := view.field_text(&snap.text, d, 2, "size")
    testing.expect_value(t, size, "3")

    // And `..` is a link like the rest: it acts on the directory above, so `enter` over it
    // needs no case of its own anywhere.
    up, has_up := view.field_text(&snap.text, d, 0, "path")
    testing.expect(t, has_up)
    testing.expect_value(t, up, filepath.dir(root))

    // The link: drawn as `top.txt`, acting on the whole of where it lives.
    path, has_path := view.field_text(&snap.text, d, 2, "path")
    testing.expect(t, has_path)
    testing.expect_value(t, path, fmt.tprintf("%s/top.txt", root))
}

// THE GATE. `enter` is a row in binds.conf, and what it does is a command line anyone can
// read: visit the directory, or fall through to the kernel's own `:open`. No callback, and the
// plugin's whole contribution to it is an exit code.
@(test)
enter_is_a_row_and_the_chain_is_the_navigation :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-enter")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    // Asked for, never claimed — and loud about what it met: this row shadows the surface-tier
    // `:open <path>` and the writeback says so above it.
    rows := read_binds(&a)
    testing.expect(t, strings.contains(rows, "# shadows :open <path>\nenter = exec :br.enter <path> && :open <path>"),
                   rows)
    // The same line on the mouse, which is the whole of what a document does to get one: a row,
    // and the plugin never sees an event (§8). DOUBLE click, because a single one lands the
    // caret on the name — clicking into a row to rename it must not also take you somewhere.
    testing.expect(t, strings.contains(rows, "double-click = exec :br.enter <path> && :open <path>"),
                   rows)
    testing.expect(t, strings.contains(rows, "click = br.snap"), rows)

    // Standing on `sub`. Enter VISITS it: the buffer becomes that directory rather than growing
    // a subtree, the chain STOPS rather than reaching `:open`, and the caret lands on a name.
    go_row(&a, 1)
    app.handle_chord(&a, chord("RTRN"))

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    testing.expect_value(t, txt.text_line_count(snap), 2)
    testing.expect_value(t, name_of(&a, 0), "..")
    testing.expect_value(t, name_of(&a, 1), "deep.txt")
    testing.expect_value(t, d.file, fmt.tprintf("%s/sub", root))
    // The FIRST entry, not the way out: you arrive somewhere to look at what is in it.
    testing.expect_value(t, point(&a).head.line, 1)
    testing.expect_value(t, point(&a).head.col, PREFIX + len("deep.txt"))

    // And back out: `ctrl+backspace` goes up a directory and lands on the row you came from.
    app.handle_chord(&a, chord("BKSP", {.Ctrl}))
    after, ad := reading(&a)
    defer txt.snapshot_release(after)
    defer desc.release(ad)
    testing.expect_value(t, ad.file, root)
    testing.expect_value(t, txt.text_line_count(after), 3)
    testing.expect_value(t, point(&a).head.line, 1)
    testing.expect_value(t, name_of(&a, 1), "sub")
}

// "A file listing navigates and OPENS." The second half of the row: over a file `br.enter` does
// nothing and answers 0, `&&` advances, and the kernel hands the path to the `edit` kind — a
// different plugin, reached with no plugin-to-plugin call anywhere.
@(test)
enter_over_a_file_falls_through_to_the_editor :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-open")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 2) // top.txt
    app.handle_chord(&a, chord("RTRN"))

    id := app.ring_focused(&a).doc
    edit, _ := app.kind_named(&a, "edit")
    testing.expect_value(t, app.doc_kind(&a, id), edit)
    testing.expect_value(t, doc_text(&a, id), "xyz")
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    testing.expect_value(t, d.file, fmt.tprintf("%s/top.txt", root))
}

// THE CARET IS PINNED. Up and down move a row and land at the end of its name — before a
// directory's slash — and nothing moves a caret sideways inside a row, which is what frees the
// other two arrows to be the hierarchy.
@(test)
the_caret_lands_at_the_end_of_every_name :: proc(t: ^testing.T) {
    a, _, ok := tree_app(t, "oket-browser-caret")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 0)
    testing.expect_value(t, point(&a).head.col, PREFIX + len("..")) // before `..`'s own slash

    app.handle_chord(&a, chord("DOWN"))
    testing.expect_value(t, point(&a).head.line, 1)
    testing.expect_value(t, point(&a).head.col, PREFIX + len("sub")) // before the slash

    app.handle_chord(&a, chord("DOWN"))
    testing.expect_value(t, point(&a).head.line, 2)
    testing.expect_value(t, point(&a).head.col, PREFIX + len("top.txt"))

    app.handle_chord(&a, chord("DOWN")) // the last row holds
    testing.expect_value(t, point(&a).head.line, 2)

    app.handle_chord(&a, chord("UP"))
    testing.expect_value(t, point(&a).head.line, 1)
    testing.expect_value(t, point(&a).head.col, PREFIX + len("sub"))
}

// The side arrows are MOTION, not the hierarchy: the browser asks for neither, so they stay the
// kernel's own `nav.left`/`nav.right` and walk the caret through the name being renamed. The
// hierarchy is `enter` and `ctrl+backspace`, and neither of those moves a caret sideways.
@(test)
the_side_arrows_move_the_caret_in_the_row :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-sides")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 1) // sub, with the caret at the end of its name
    was := point(&a).head
    app.handle_chord(&a, chord("LEFT"))
    testing.expect_value(t, point(&a).head.col, was.col - 1)
    testing.expect_value(t, point(&a).head.line, was.line)

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    testing.expect_value(t, d.file, root) // the listing did not go anywhere

    app.handle_chord(&a, chord("RGHT"))
    testing.expect_value(t, point(&a).head.col, was.col)

    // And the way out is the chord that says so, from any column of the row.
    app.handle_chord(&a, chord("RTRN")) // into `sub`
    app.handle_chord(&a, chord("BKSP", {.Ctrl}))
    after, ad := reading(&a)
    defer txt.snapshot_release(after)
    defer desc.release(ad)
    testing.expect_value(t, ad.file, root)
    testing.expect_value(t, point(&a).head.line, 1)
}

// The listing, through the kernel's one renderer. The mode, the size and the date are the
// platter's and move under a test, so what is asserted is the shape: a fixed prefix, the name
// last, and a subtree indented in the NAME column rather than the whole row.
@(test)
the_listing_draws_ls_la_through_the_kernels_renderer :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-draw")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.cl_exec(&a, fmt.tprintf(":br.toggle %s/sub", root)) // the subtree, opened in place
    app.surface_fit(&a, 70, 5)
    app.surface_draw(&a)
    // The panel diffs on its own (PANELS.md §7): the listing is four rows of text with no bar
    // row to trim off the end of it.
    snap := gfx.grid_snapshot(panel_grid(&a))
    defer delete(snap)
    rows := strings.split_lines(snap, context.temp_allocator)

    testing.expect_value(t, len(rows), 4)
    for want, i in ([?]string{"../", "sub/", "  deep.txt", "top.txt"}) {
        testing.expect(t, strings.has_prefix(rows[i], "drwx") || strings.has_prefix(rows[i], "-rw-"),
                       rows[i])
        testing.expect(t, strings.has_suffix(rows[i], want), rows[i])
        testing.expect_value(t, len(rows[i]), PREFIX + len(want))
    }
    bar := gfx.grid_snapshot(&a.chrome, context.temp_allocator)
    testing.expect(t, strings.has_prefix(strings.split_lines(bar, context.temp_allocator)[4],
                                         "files 1"), bar)
}

// §14 answered the other way round. Hover underlines the name because the link's SPAN is the
// name — the row draws one string and acts on another, and the two no longer have to contain
// each other for the underline to be honest. Over the mode bits it underlines nothing, because
// the narrowest field there is not one a bound click would act on.
@(test)
hover_underlines_the_link_it_would_follow :: proc(t: ^testing.T) {
    a, _, ok := tree_app(t, "oket-browser-hover")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.hover_update(&a, 0, PREFIX + 2, 2) // inside the name
    testing.expect(t, app.panel_focused(&a).hover.on, "the name a bound click acts on is not underlined")
    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    lo, hi, _ := desc.field_span(d, 2, "path")
    testing.expect_value(t, app.panel_focused(&a).hover.lo, lo)
    testing.expect_value(t, app.panel_focused(&a).hover.hi, hi)

    app.hover_update(&a, 0, 2, 2) // the mode bits, which no click acts on
    testing.expect(t, !app.panel_focused(&a).hover.on, "the mode column underlined as though a click acted on it")
}

// §8's rule as data: a directory row carries no `file` field, so a row asking for one REPORTS
// rather than running with a hole still in it. A file row fills the same hole.
@(test)
a_directory_row_cannot_fill_the_file_hole :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-hole")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 2) // top.txt
    line, filled := app.bind_expand(&a, "echo <file>")
    testing.expect(t, filled, a.message)
    testing.expect_value(t, line, fmt.tprintf("echo %s/top.txt", root))

    go_row(&a, 1) // sub, a directory
    _, dir_filled := app.bind_expand(&a, "echo <file>")
    testing.expect(t, !dir_filled, "a directory filled a hole only a file carries")
    testing.expect(t, strings.contains(a.message, "nothing here has a file"), a.message)
}

// A value that is not the text it is drawn over. `<path>` resolves to a whole path from a span
// that shows a bare name, which is the other half of the link and the thing a span alone could
// never say.
@(test)
a_value_that_is_not_what_it_draws :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-value")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    name, hi, _ := desc.field_span(d, 2, "name")
    path_lo, path_hi, _ := desc.field_span(d, 2, "path")
    testing.expect_value(t, path_lo, name) // the same bytes...
    testing.expect_value(t, path_hi, hi)
    shown, _ := view.field_text(&snap.text, d, 2, "name")
    acted, _ := view.field_text(&snap.text, d, 2, "path")
    testing.expect_value(t, shown, "top.txt") // ...drawn as one string
    testing.expect_value(t, acted, fmt.tprintf("%s/top.txt", root)) // ...acting as another
}

// A browser takes typing and names a DIRECTORY, and a journal replaying a listing into one
// recovers nothing. So `editable` and `file` stop being enough to say what is journaled, and
// the two questions part company there rather than in a new descriptor field (§14).
@(test)
a_browser_is_not_journaled :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-journal")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 2)
    app.text_input(&a, 'x')
    app.docs_settle(&a) // where the journal is armed, every frame after the drain
    testing.expect(t, !os.exists(app.journal_path(&a, root)),
                   "a directory listing was written down as work to recover")
}

// TYPING RENAMES, and it is CLAMPED INTO THE NAME. The document is a text field, so a rune
// reaches the plugin and the plugin splices it — into the name of the row point is on, wherever
// the caret happens to be, which is what makes the mode bits and the date unwritable with no
// mode and no second document. What the row POINTS at does not move: the link still names the
// file on disk, which is what a commit renames FROM.
@(test)
typing_renames_and_the_link_still_names_the_file :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-type")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 2) // top.txt, caret at the end of the name
    for r in "_v2" {
        app.text_input(&a, r)
    }
    testing.expect_value(t, name_of(&a, 2), "top.txt_v2")
    testing.expect_value(t, point(&a).head.col, PREFIX + len("top.txt_v2"))

    // The caret dragged into the mode column types into the name anyway, and the mode bits
    // survive it.
    txt.doc_set_head(doc_of(&a), {2, 0}, false)
    app.point_sync(&a)
    app.text_input(&a, 'z')
    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    testing.expect_value(t, name_of(&a, 2), "ztop.txt_v2")
    testing.expect(t, strings.has_prefix(line_text(snap, 2), "-rw-"), line_text(snap, 2))
    // The link rode the splice: its span grew with the name, its value is still the file.
    path, _ := view.field_text(&snap.text, d, 2, "path")
    testing.expect_value(t, path, fmt.tprintf("%s/top.txt", root))
}

// The commit: every row whose text stopped matching its link is renamed on disk, and nothing
// else is touched. One key, and the diff between the two is the whole of what it does.
@(test)
commit_renames_every_row_that_was_typed_over :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-commit")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 2)
    for r in "_v2" {
        app.text_input(&a, r)
    }
    app.handle_chord(&a, chord("AC02", {.Ctrl})) // ctrl+s, shadowed for this kind

    testing.expect(t, strings.contains(a.message, "1 renamed, 0 refused"), a.message)
    _, err := os.stat(fmt.tprintf("%s/top.txt_v2", root), context.temp_allocator)
    testing.expect(t, err == nil, "the file was not renamed on disk")
    _, gone := os.stat(fmt.tprintf("%s/top.txt", root), context.temp_allocator)
    testing.expect(t, gone != nil, "the old name is still there")

    // And the listing came back from the platter, so the link names what the file is called now.
    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    path, _ := view.field_text(&snap.text, d, 2, "path")
    testing.expect_value(t, path, fmt.tprintf("%s/top.txt_v2", root))
}

// A name that would land on a file that already exists is REFUSED, not overwritten, and said
// out loud. The one failure in a rename worth being loud about.
@(test)
commit_refuses_a_name_that_is_taken :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-taken")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    other, _ := filepath.join({root, "taken.txt"}, context.temp_allocator)
    _ = os.write_entire_file(other, transmute([]u8)string("keep me"))
    app.cl_exec(&a, ":br.reload")

    go_row(&a, 3) // top.txt, which sorts after taken.txt
    for _ in 0 ..< 20 {
        app.handle_chord(&a, chord("BKSP")) // stops at the head of the name, however long
    }
    testing.expect_value(t, name_of(&a, 3), "")
    for r in "taken.txt" {
        app.text_input(&a, r)
    }
    app.handle_chord(&a, chord("AC02", {.Ctrl}))

    testing.expect(t, strings.contains(a.message, "0 renamed, 1 refused"), a.message)
    kept, _ := os.read_entire_file(other, context.temp_allocator)
    testing.expect_value(t, string(kept), "keep me")
}

// Backspace stops at the head of the NAME, so it can neither eat the mode bits nor join two
// rows. The kernel's own delete verb is shadowed for this kind alone rather than the kernel
// growing a rule about it.
@(test)
backspace_stops_at_the_head_of_the_name :: proc(t: ^testing.T) {
    a, _, ok := tree_app(t, "oket-browser-erase")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 2)
    app.handle_chord(&a, chord("BKSP"))
    testing.expect_value(t, name_of(&a, 2), "top.tx")

    for _ in 0 ..< 20 {
        app.handle_chord(&a, chord("BKSP"))
    }
    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    testing.expect_value(t, txt.text_line_count(snap), 3) // no row was joined to the one above
    testing.expect_value(t, name_of(&a, 2), "")
    testing.expect(t, strings.has_prefix(line_text(snap, 2), "-rw-"), line_text(snap, 2))
    testing.expect_value(t, len(line_text(snap, 2)), PREFIX) // the prefix, and nothing after it
}

// ctrl+f filters the listing: typed runes go to the filter, not into a name, and the rows
// shrink to the matches. `..` stays — a filtered listing still needs its way out — but point
// lands on the first MATCH, so enter goes into it rather than up. The browser has no head row,
// so the filter reports through the echo line, and esc brings the whole listing back.
@(test)
the_filter_hides_rows_and_keeps_the_way_out :: proc(t: ^testing.T) {
    a, _, ok := tree_app(t, "oket-browser-filter")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.handle_chord(&a, chord("AC04", {.Ctrl})) // ctrl+f arms the filter
    for r in "top" {
        app.text_input(&a, r)
    }
    {
        snap, d := reading(&a)
        defer txt.snapshot_release(snap)
        defer desc.release(d)
        testing.expect_value(t, txt.text_line_count(snap), 2) // `..` and the match
    }
    testing.expect_value(t, name_of(&a, 0), "..")
    testing.expect_value(t, name_of(&a, 1), "top.txt") // the runes went to the filter
    testing.expect_value(t, point(&a).head.line, 1)
    testing.expect(t, strings.contains(a.message, "2 shown"), a.message) // `..` counts: it is shown

    app.handle_chord(&a, chord("ESC")) // clears the filter; shadowed, so it does not quit
    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    testing.expect_value(t, txt.text_line_count(snap), 3)
}

// A hole fills QUOTED when its value would re-parse (§8), so the step that reaches a plugin
// carries the quotes. `br.enter` is where that line ends and it wants the value: a directory
// whose name holds a space is visited like any other, and nothing in the plugin reads a quote.
@(test)
a_path_with_a_space_is_visited_like_any_other :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-space")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    spaced, _ := filepath.join({root, "two words"}, context.temp_allocator)
    inner, _ := filepath.join({spaced, "in.txt"}, context.temp_allocator)
    _ = os.make_directory(spaced)
    _ = os.write_entire_file(inner, transmute([]u8)string("xyz"))
    app.cl_exec(&a, ":br.reload")
    testing.expect_value(t, txt.doc_line_count(doc_of(&a)), 4)

    go_row(&a, 2) // sub, "two words", top.txt — directories first
    app.handle_chord(&a, chord("RTRN"))

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    testing.expect_value(t, d.file, fmt.tprintf("%s/two words", root))
    testing.expect_value(t, name_of(&a, 1), "in.txt")
}

// THE KERNEL OPENS NO LISTING OF ITS OWN. A directory is the `files` kind's, exactly as a file
// is `edit`'s, so with nothing registered `:open` REPORTS: a kernel-made `files` document would
// take every `[files]` row and be able to answer none of them.
@(test)
a_directory_with_no_browser_reports :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    _, opened := app.files_open(&a, ".")
    testing.expect(t, !opened, "a directory opened with nothing registered to open one")
    testing.expect(t, strings.contains(a.message, "nothing registers the files kind"), a.message)
    testing.expect_value(t, len(store.store_ids(&a.docs)), 0)
}

// `..` is a way OUT and not an entry, so it renames to nothing: typing and backspace pass over
// it, and the commit skips it rather than trying to rename the directory you came from.
@(test)
the_way_out_is_not_a_name :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-dotdot")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_row(&a, 0)
    for r in "xyz" {
        app.text_input(&a, r)
    }
    for _ in 0 ..< 5 {
        app.handle_chord(&a, chord("BKSP"))
    }
    testing.expect_value(t, name_of(&a, 0), "..")

    app.handle_chord(&a, chord("AC02", {.Ctrl}))
    testing.expect(t, strings.contains(a.message, "0 renamed, 0 refused"), a.message)
    _, err := os.stat(root, context.temp_allocator)
    testing.expect(t, err == nil, "the directory above was renamed")

    // And it is still a link: enter over it goes up, which is the whole reason it is a row.
    app.handle_chord(&a, chord("RTRN"))
    d := store.store_descriptor(&a.docs, app.ring_focused(&a).doc)
    defer desc.release(d)
    testing.expect_value(t, d.file, filepath.dir(root))
}

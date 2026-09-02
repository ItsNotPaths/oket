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

// Stage 10's gate (§13): a file tree navigates and opens, and `enter` is a binds.conf row
// rather than a callback. What is really being asked is whether `fields`, `columns`, `depth`
// and `selection: line` are enough to be a TUI with the kernel drawing every cell of it.
//
// The subject is plugins/browser, built by plugins/stage.sh. plugins/edit is loaded beside it,
// because "opens" means a row reaches a DIFFERENT plugin through the kernel's own `:open`.

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
    root, _ = filepath.join({a.home, "tree"}, context.temp_allocator)
    sub, _ := filepath.join({root, "sub"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(sub)
    for f in ([?][2]string{{root, "top.txt"}, {sub, "deep.txt"}}) {
        path, _ := filepath.join({f[0], f[1]}, context.temp_allocator)
        _ = os.write_entire_file(path, transmute([]u8)string("xyz"))
    }

    kind, _ := app.kind_named(&a, "browser")
    id, opened := app.plug_open(&a, kind, root)
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
    id := app.ring_focused(&a.ring).doc
    return store.store_snapshot(&a.docs, id), store.store_descriptor(&a.docs, id)
}

// The shape of the thing: rows the kernel draws from a descriptor, a depth per line, and the
// two spans over one cell that let a row DRAW its name and ACT on its path.
@(test)
a_tree_is_rows_a_depth_and_two_spans :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-shape")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)

    kind, _ := app.kind_named(&a, "browser")
    testing.expect_value(t, d.kind, kind)
    testing.expect_value(t, d.ctx, input.Bind_Ctx.Surface)
    testing.expect_value(t, d.selection, desc.Selection.Line) // rows, not characters (§5)
    testing.expect(t, !d.editable, "a tree that takes typing")

    // The root, then its children with directories first: three rows, and the depth is what
    // says which of them is nested. Every line past the first is also what catches a field
    // span measured from the DOCUMENT rather than from its own line.
    testing.expect_value(t, txt.text_line_count(snap), 3)
    for want, line in ([?]struct {
        name:  string,
        depth: int,
    }{{"tree", 0}, {"sub", 1}, {"top.txt", 1}}) {
        shown, _ := view.field_text(&snap.text, d, line, "name")
        testing.expect_value(t, shown, want.name)
        testing.expect_value(t, desc.line_depth(d, line), want.depth)
    }
    // Two spans over one cell: `<path>` hands on the whole of it, `name` is its tail.
    path, has_path := view.field_text(&snap.text, d, 2, "path")
    testing.expect(t, has_path)
    testing.expect_value(t, path, fmt.tprintf("%s/top.txt", root))
}

// THE GATE. `enter` is a row in binds.conf, and what it does is a command line anyone can
// read: expand the directory, or fall through to the kernel's own `:open`. No callback, and
// the plugin's whole contribution to it is an exit code.
@(test)
enter_is_a_row_and_the_chain_is_the_navigation :: proc(t: ^testing.T) {
    a, _, ok := tree_app(t, "oket-browser-enter")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    // Asked for, never claimed — and loud about what it met: this row shadows the surface-tier
    // `:open <path>` and the writeback says so above it.
    rows := read_binds(&a)
    testing.expect(t, strings.contains(rows, "# shadows :open <path>\nenter = exec :br.toggle <path> && :open <path>"),
                   rows)
    // The same line on `click`, which is the whole of what a document does to get the mouse: no
    // default claims it, so it goes in clean and the plugin never sees an event (§8).
    testing.expect(t, strings.contains(rows, "click = exec :br.toggle <path> && :open <path>"),
                   rows)

    // Standing on `sub`, a collapsed directory. Enter expands it in place: its child arrives
    // one level deeper, and the chain STOPS rather than reaching `:open`.
    doc := store.store_doc(&a.docs, app.ring_focused(&a.ring).doc)
    txt.doc_set_head(doc, {1, 0}, false)
    app.point_sync(&a)
    app.handle_chord(&a, chord("RTRN"))

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    testing.expect_value(t, txt.text_line_count(snap), 4)
    child, _ := view.field_text(&snap.text, d, 2, "name")
    testing.expect_value(t, child, "deep.txt")
    testing.expect_value(t, desc.line_depth(d, 2), 2)

    // And point did not move. A document that takes no typing is REGENERATED rather than
    // edited, so the carets stay where navigation put them instead of collapsing onto the
    // splice — without that rule a tree cannot be walked at all.
    testing.expect_value(t, point(&a).head.line, 1)
    marker, _ := view.field_text(&snap.text, d, 1, "mark")
    testing.expect_value(t, marker, "-")

    // And the mouse, over the same row and through the same line: point first, then the chord.
    app.point_place(&a, 6, 1)
    app.handle_chord(&a, input.Chord{input.mouse_code(.Click), {}})
    after := store.store_snapshot(&a.docs, app.ring_focused(&a.ring).doc)
    defer txt.snapshot_release(after)
    testing.expect_value(t, txt.text_line_count(after), 3) // collapsed again
}

// "A file tree navigates and OPENS." The second half of the row: over a file `br.toggle` does
// nothing and answers 0, `&&` advances, and the kernel hands the path to the `edit` kind — a
// different plugin, reached with no plugin-to-plugin call anywhere.
@(test)
enter_over_a_file_falls_through_to_the_editor :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-open")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    doc := store.store_doc(&a.docs, app.ring_focused(&a.ring).doc)
    txt.doc_set_head(doc, {2, 0}, false) // top.txt
    app.point_sync(&a)
    app.handle_chord(&a, chord("RTRN"))

    id := app.ring_focused(&a.ring).doc
    edit, _ := app.kind_named(&a, "edit")
    testing.expect_value(t, app.doc_kind(&a, id), edit)
    testing.expect_value(t, doc_text(&a, id), "xyz")
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    testing.expect_value(t, d.file, fmt.tprintf("%s/top.txt", root))
}

// The tree, through the kernel's one renderer: `depth` is the indent and `columns` place the
// marker and the name. Nothing in the plugin drew a cell or padded a string.
@(test)
the_tree_draws_indented_through_the_kernels_renderer :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-draw")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    gfx.grid_destroy(&a.grid)
    testing.expect(t, gfx.grid_init(&a.grid, 70, 4))
    app.surface_draw(&a)
    snap := gfx.grid_snapshot(&a.grid)
    defer delete(snap)

    testing.expect_value(t, snap, fmt.tprintf(`- tree
  + sub
    top.txt
browser 1  %s`, root))
}

// §14, answered. Hover underlines the NAME because the field the row acts on CONTAINS it. Over
// the marker it underlines nothing: a marker is a control, not a value, so there is no span a
// click could honestly be said to act on — which is the containment rule refusing to guess
// rather than the rule falling short.
@(test)
hover_underlines_the_name_and_not_the_marker :: proc(t: ^testing.T) {
    a, _, ok := tree_app(t, "oket-browser-hover")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    // Row 2 is one level in, so the marker sits at cell 2 and the name column starts at 5.
    app.hover_update(&a, 6, 2)
    testing.expect(t, a.hover.on, "the name a bound click acts on is not underlined")
    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    lo, hi, _ := desc.field_span(d, 2, "name")
    testing.expect_value(t, a.hover.lo, lo)
    testing.expect_value(t, a.hover.hi, hi)

    app.hover_update(&a, 2, 2) // the marker of the same row
    testing.expect(t, !a.hover.on, "the marker underlined as though a click acted on it")
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

    doc := store.store_doc(&a.docs, app.ring_focused(&a.ring).doc)
    txt.doc_set_head(doc, {2, 0}, false) // top.txt
    app.point_sync(&a)
    line, filled := app.bind_expand(&a, "echo <file>")
    testing.expect(t, filled, a.message)
    testing.expect_value(t, line, fmt.tprintf("echo %s/top.txt", root))

    txt.doc_set_head(doc, {1, 0}, false) // sub, a directory
    app.point_sync(&a)
    _, dir_filled := app.bind_expand(&a, "echo <file>")
    testing.expect(t, !dir_filled, "a directory filled a hole only a file carries")
    testing.expect(t, strings.contains(a.message, "nothing here has a file"), a.message)
}

// A value the descriptor names and no column draws still fills a hole. Which is the other half
// of §14: what a row ACTS on and what it SHOWS are two questions, and only the second one is
// the columns'.
@(test)
an_undrawn_field_still_fills_a_hole :: proc(t: ^testing.T) {
    a, _, ok := tree_app(t, "oket-browser-undrawn")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    for c in d.columns {
        testing.expect(t, c.name != "size", "size is drawn after all, so this proves nothing")
    }
    size, has_size := view.field_text(&snap.text, d, 2, "size")
    testing.expect(t, has_size)
    testing.expect_value(t, size, "3")
}

// A regeneration can be SHORTER than the rows the carets stand on: re-rooting into `sub` while
// point is on the last row must clamp it onto a real line, or every read after it indexes past
// the document.
@(test)
a_shrinking_regeneration_clamps_point :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-shrink")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    doc := store.store_doc(&a.docs, app.ring_focused(&a.ring).doc)
    txt.doc_set_head(doc, {1, 0}, false) // sub
    app.point_sync(&a)
    app.handle_chord(&a, chord("RTRN")) // expanded: tree, sub, deep.txt, top.txt
    txt.doc_set_head(doc, {3, 0}, false) // top.txt, the last row
    app.point_sync(&a)
    app.cl_exec(&a, fmt.tprintf(":br.root %s/sub", root))
    testing.expect_value(t, txt.doc_line_count(doc), 2) // sub, deep.txt
    testing.expect_value(t, point(&a).head.line, 1)
}

// A hole fills QUOTED when its value would re-parse (§8), so the step that reaches a plugin
// carries the quotes. `br.toggle` is where that line ends and it wants the value: a directory
// whose name holds a space expands like any other, and nothing in the plugin reads a quote.
// `:br.root` is the same argument typed by hand.
@(test)
a_path_with_a_space_expands_like_any_other :: proc(t: ^testing.T) {
    a, root, ok := tree_app(t, "oket-browser-space")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    spaced, _ := filepath.join({root, "two words"}, context.temp_allocator)
    inner, _ := filepath.join({spaced, "in.txt"}, context.temp_allocator)
    _ = os.make_directory(spaced)
    _ = os.write_entire_file(inner, transmute([]u8)string("xyz"))
    app.cl_exec(&a, fmt.tprintf(":br.root %s", root)) // rebuilds where it stands
    doc := store.store_doc(&a.docs, app.ring_focused(&a.ring).doc)
    testing.expect_value(t, txt.doc_line_count(doc), 4)
    txt.doc_set_head(doc, {2, 0}, false) // sub, "two words", top.txt — directories first
    app.point_sync(&a)
    app.handle_chord(&a, chord("RTRN"))

    snap, d := reading(&a)
    defer txt.snapshot_release(snap)
    defer desc.release(d)
    child, _ := view.field_text(&snap.text, d, 3, "name")
    testing.expect_value(t, child, "in.txt")
    testing.expect_value(t, desc.line_depth(d, 3), 2)
}

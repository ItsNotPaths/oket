package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "../desc"
import "../input"
import "../store"
import "../txt"
import app "../oket"

// Stage 8's gate (§13), and it is a DESIGN gate: the editor is a plugin, with no privileged
// path and no kernel self-insert. If the seam could not express one, §5 would be redesigned
// rather than patched.
//
// The subject is plugins/edit, built by plugins/stage.sh like any other plugin. What these
// tests are really asking is whether the six messages plus a descriptor are enough to be an
// editor, and each one names the rule it would catch breaking.

// The editor loaded, with a file already open through the kernel's `:open` — which is the only
// door a document comes through, and the plugin is what walks through it.
@(private = "file")
edit_app :: proc(t: ^testing.T, name, text: string) -> (a: app.App, path: string, ok: bool) {
    a = plug_app(t, name, "plugins/edit") or_return
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "edit")), a.message) {
        close_plug_app(&a)
        return {}, "", false
    }
    path, _ = filepath.join({a.home, "note.txt"}, context.temp_allocator)
    if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", path, err)
        close_plug_app(&a)
        return {}, "", false
    }
    app.cl_exec(&a, fmt.tprintf(":open %s", path))
    if !testing.expect(t, app.ring_focused(&a) != nil, a.message) {
        close_plug_app(&a)
        return {}, "", false
    }
    app.surface_draw(&a) // the body rectangle, so a viewport has a height to follow in
    return a, path, true
}

@(private = "file")
focused :: proc(a: ^app.App) -> store.Id {
    return app.ring_focused(a).doc
}

// The whole shape in one pass: a file the kernel does not read reaches a plugin that does, and
// what comes back is an ordinary document — one the kernel's own renderer draws and the bind
// table routes, with the kind saying so.
@(test)
a_file_opens_into_the_editor_plugin :: proc(t: ^testing.T) {
    a, path, ok := edit_app(t, "oket-edit-open", "alpha\nbeta\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := focused(&a)
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    kind, _ := app.kind_named(&a, "edit")
    testing.expect_value(t, d.kind, kind)
    testing.expect_value(t, d.file, path)
    testing.expect_value(t, d.ctx, input.Bind_Ctx.Text)
    testing.expect(t, d.editable, "an editor buffer that does not take typing")
    // `bound`, not `raw`: an editor's chords go through the bind table like everything else,
    // which is what keeps describe able to answer for them (§8).
    testing.expect_value(t, d.input, desc.Input.Bound)
    testing.expect_value(t, doc_text(&a, id), "alpha\nbeta\n")

    // With no editor loaded there is no kind to hand a file to, and the kernel says so rather
    // than opening one itself. That refusal IS the rule stage 8 is about.
    app.plug_unload(&a, app.plug_find(&a, "edit"))
    app.cl_exec(&a, fmt.tprintf(":open %s", path))
    testing.expect(t, strings.contains(a.message, "nothing registers"), a.message)
    // Nothing new landed in the ring: the slot still holds the document the unload closed.
    testing.expect(t, !store.store_is_open(&a.docs, focused(&a)),
                   "the kernel opened a file by itself")
}

// No kernel self-insert (§7). A rune reaches the document's OWNER and nobody else: the same
// keystroke over an editable document with no owner behind it writes nothing at all.
@(test)
typing_reaches_the_owner_and_the_kernel_writes_nothing :: proc(t: ^testing.T) {
    a, _, ok := edit_app(t, "oket-edit-typing", "ab\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := focused(&a)
    app.handle_chord(&a, chord("END")) // the kernel's own motion, over a plugin's document
    for r in "XY" {
        app.text_input(&a, r)
    }
    testing.expect_value(t, doc_text(&a, id), "abXY\n")
    // The caret came back with the edit and the kernel copied it into the viewport, so the
    // frame draws it where the text now ends.
    testing.expect_value(t, point(&a).head, txt.Pos{0, 4})

    // Editable, focused, and nobody's: the rune has nowhere to go, and the kernel is not a
    // fallback for it. A kernel self-insert is what would make this line "aXb".
    app.ring_add(&a, scratch_doc(&a, "orphan", "ab"))
    app.text_input(&a, 'X')
    testing.expect_value(t, doc_text(&a, focused(&a)), "ab")
}

// Two runes in one frame. Both are written against the generation the first one moves, so the
// drain would drop the second whole — unless a plugin's transaction lands when its CALL
// returns. This is the test that says why the seam drains per call and not per frame.
@(test)
fast_typing_never_loses_a_rune :: proc(t: ^testing.T) {
    a, _, ok := edit_app(t, "oket-edit-fast", "")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := focused(&a)
    for r in "hello" {
        app.text_input(&a, r) // no frame between any two of them
    }
    testing.expect_value(t, doc_text(&a, id), "hello")
}

// The verbs that are policy are the plugin's, and it gets them the way any plugin gets a key:
// it ASKS, the row lands in binds.conf under its own kind, and the file decides (§8). The row
// shadows the kernel's plain `edit.newline` for this kind alone — which is what lets an editor
// have an opinion about Enter without taking one away from the command line.
@(test)
the_plugins_own_newline_shadows_the_kernels :: proc(t: ^testing.T) {
    a, _, ok := edit_app(t, "oket-edit-newline", "    indented")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    rows := read_binds(&a)
    testing.expect(t, strings.contains(rows, "enter = ed.newline"), rows)
    testing.expect(t, strings.contains(rows, "# shadows edit.newline"), rows)

    id := focused(&a)
    app.handle_chord(&a, chord("END"))
    app.handle_chord(&a, chord("RTRN"))
    testing.expect_value(t, doc_text(&a, id), "    indented\n    ")

    // And Tab, whose stop is a COLUMN and not a byte: four spaces from the caret's cell.
    app.handle_chord(&a, chord("TAB"))
    testing.expect_value(t, doc_text(&a, id), "    indented\n        ")
}

// What oket_batch exists for: one edit per cursor, and each caret takes its OWN line's indent
// — two different strings in one transaction, which is one undo step (§6).
@(test)
each_caret_takes_its_own_indent_in_one_step :: proc(t: ^testing.T) {
    a, _, ok := edit_app(t, "oket-edit-carets", "  two\n        eight")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := focused(&a)
    doc := store.store_doc(&a.docs, id)
    txt.doc_set_head(doc, {0, 5}, false) // end of "  two"
    txt.doc_add_cursor(doc, {1, 13}) // end of "        eight"

    app.handle_chord(&a, chord("RTRN"))
    testing.expect_value(t, doc_text(&a, id), "  two\n  \n        eight\n        ")

    app.handle_chord(&a, chord("AB01", {.Ctrl})) // ctrl+z, once
    testing.expect_value(t, doc_text(&a, id), "  two\n        eight")
}

// CURSORS.md stage 3's gate, end to end: the plugin sends one edit per caret and NAMES each
// one, so the caret an edit leaves is the same caret. That is what keeps `primary` — and the
// viewport that follows it — on the caret being typed at, not the topmost (VIEWS.md §12).
@(test)
the_viewport_follows_the_caret_being_typed_at :: proc(t: ^testing.T) {
    LINES :: 200

    body := strings.builder_make(context.temp_allocator)
    for i in 0 ..< LINES {
        fmt.sbprintf(&body, "line %d\n", i)
    }
    a, _, ok := edit_app(t, "oket-edit-follow", strings.to_string(body))
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := focused(&a)
    doc := store.store_doc(&a.docs, id)
    txt.doc_set_head(doc, {0, 0}, false)
    txt.doc_add_cursor(doc, {LINES - 1, 0}) // alt+click at the bottom, and it is the primary
    bottom := doc.cursors[doc.primary].id

    app.text_input(&a, 'X')
    app.surface_draw(&a)

    testing.expect_value(t, len(doc.cursors), 2)
    testing.expect_value(t, doc.cursors[doc.primary].id, bottom)
    testing.expect_value(t, doc.cursors[doc.primary].head.line, LINES - 1)
    testing.expect(t, app.active(&a).view.top > 0, "the viewport scrolled back to the top caret")
}

// Undo is the kernel's (§7), so it reaches a plugin's transaction with the plugin writing no
// undo code. The same rule is what makes `ctrl+z` undo a formatter.
@(test)
undo_reaches_a_plugins_edit :: proc(t: ^testing.T) {
    a, _, ok := edit_app(t, "oket-edit-undo", "keep")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := focused(&a)
    app.handle_chord(&a, chord("END"))
    app.text_input(&a, '!')
    testing.expect_value(t, doc_text(&a, id), "keep!")
    app.handle_chord(&a, chord("AB01", {.Ctrl})) // ctrl+z
    testing.expect_value(t, doc_text(&a, id), "keep")
    app.handle_chord(&a, chord("AB01", {.Ctrl, .Shift}))
    testing.expect_value(t, doc_text(&a, id), "keep!")
}

// `:w` is the plugin's, because what a file IS on disk is what its opener knew. The kernel's
// own verb is a dump beside the binary and knows no paths at all — the recovery floor, and the
// reason a document nothing opened can still get its bytes out.
@(test)
the_plugin_writes_the_file_and_the_kernel_only_dumps :: proc(t: ^testing.T) {
    a, path, ok := edit_app(t, "oket-edit-write", "one\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.handle_chord(&a, chord("END"))
    app.text_input(&a, '!')
    app.cl_exec(&a, ":w")
    testing.expect(t, strings.contains(a.message, "wrote"), a.message)
    on_disk, _ := os.read_entire_file(path, context.temp_allocator)
    testing.expect_value(t, string(on_disk), "one!\n")

    // The kernel's floor, over a document no plugin owns: beside the binary, named for what the
    // document is called, and never over the file itself.
    app.ring_add(&a, scratch_doc(&a, "orphan.txt", "rescue me"))
    app.handle_chord(&a, chord("AC02", {.Ctrl})) // ctrl+s, which no [edit] row shadows here
    dumped, _ := filepath.join({a.home, "orphan.txt.dump"}, context.temp_allocator)
    raw, err := os.read_entire_file(dumped, context.temp_allocator)
    testing.expectf(t, err == nil, "%s: %v (%s)", dumped, err, a.message)
    testing.expect_value(t, string(raw), "rescue me")
}

// --- the file, changing underneath (stage 12) ---

// The other half of stage 12's gate (§13): a `watch` reload, with nothing on a plugin thread.
// The kernel watches the path because the plugin asked through the seam, and the plugin is told
// on the main thread and re-reads.
@(test)
a_file_changed_on_disk_is_taken_back :: proc(t: ^testing.T) {
    a, path, ok := edit_app(t, "oket-edit-watch", "alpha\nbeta\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    _ = os.write_entire_file(path, transmute([]u8)string("alpha\ngamma\n"))
    testing.expect(t, io_settle(&a, focused_text, "alpha\ngamma\n"), a.message)
}

// Written somewhere else and moved on top, which is how most programs write a file — and what a
// watch on the file itself would miss, because the inode it holds is not the one that lands.
@(test)
a_save_by_rename_is_taken_back :: proc(t: ^testing.T) {
    a, path, ok := edit_app(t, "oket-edit-rename", "alpha\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    tmp, _ := filepath.join({a.home, "note.new"}, context.temp_allocator)
    _ = os.write_entire_file(tmp, transmute([]u8)string("renamed\n"))
    _ = os.rename(tmp, path)
    testing.expect(t, io_settle(&a, focused_text, "renamed\n"), a.message)
}

// A buffer with edits of its own is NOT overwritten. Two edits of one file is the case where
// the honest answer is to say so and change nothing.
@(test)
an_edited_buffer_is_not_overwritten :: proc(t: ^testing.T) {
    a, path, ok := edit_app(t, "oket-edit-clash", "alpha\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.plug_type(&a, focused(&a), 'x')
    mine := doc_text(&a, focused(&a))
    _ = os.write_entire_file(path, transmute([]u8)string("theirs\n"))
    for _ in 0 ..< 200 {
        app.io_pump(&a)
        time.sleep(5 * time.Millisecond)
    }
    testing.expect_value(t, doc_text(&a, focused(&a)), mine)
    testing.expect(t, strings.contains(a.message, "changed on disk"), a.message)
}

// Our own `:w` comes back through the same watch, and it must not land as a reload: the
// baseline moved when we wrote, so there is nothing to take back and the caret does not move.
@(test)
a_save_of_our_own_is_not_a_reload :: proc(t: ^testing.T) {
    a, _, ok := edit_app(t, "oket-edit-selfsave", "alpha\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.plug_type(&a, focused(&a), 'x')
    app.cl_exec(&a, ":w")
    testing.expect(t, strings.contains(a.message, "wrote"), a.message)
    before := doc_text(&a, focused(&a))
    for _ in 0 ..< 200 {
        app.io_pump(&a)
        time.sleep(5 * time.Millisecond)
    }
    testing.expect_value(t, doc_text(&a, focused(&a)), before)
    testing.expect(t, !strings.contains(a.message, "changed on disk"), a.message)
}

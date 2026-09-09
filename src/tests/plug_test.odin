package tests

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

// Stage 7's gate (§13): a plugin registers, opens, renders and unloads clean; the ledger
// reverts everything; and a helper call inlines into the plugin under -flto.
//
// The subject is plugins/example, built by plug_app in support_test.odin.

// The whole gate in one pass: it registers, it opens, what it opened renders through the
// kernel's own renderer, and unloading reverts every registration.
@(test)
a_plugin_registers_opens_renders_and_unloads :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-gate")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)

    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "example")), a.message) {
        return
    }

    // --- register ---
    kind, named := app.kind_named(&a, "example")
    testing.expect(t, named, "the kind it registered is not in the table")
    testing.expect(t, int(kind) > len(app.KINDS), "a plugin kind appends PAST the kernel's own")
    testing.expect_value(t, app.kind_name(&a, kind), "example")
    _, is_cmd := app.plug_cmd_named(&a, "example")
    testing.expect(t, is_cmd, ":example did not register")
    // Asked for, not claimed: the row is text in the user's file and the file decides (§8).
    row := strings.contains(read_binds(&a), "alt+h = exec :ring example")
    testing.expect(t, row, "the requested bind never reached binds.conf")

    // --- open, and render ---
    id, opened := app.kind_fresh(&a, kind)
    testing.expect(t, opened, "the kind opened nothing")
    app.ring_add(&a, id)
    snap := store.store_snapshot(&a.docs, id)
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    testing.expect_value(t, txt.text_line_count(snap), 4)
    testing.expect_value(t, d.kind, kind)
    testing.expect_value(t, d.ctx, input.Bind_Ctx.Surface)
    testing.expect_value(t, len(d.columns), 2)
    // The fields the helper library's builder recorded, which is what `<name>` resolves off.
    name, name_ok := view.field_text(&snap.text, d, 0, "name")
    testing.expect(t, name_ok)
    testing.expect_value(t, name, "kind")

    // Drawn by the kernel's one renderer, with no arm of its own: a plugin produces a document
    // and a descriptor, and that is the whole of what it produces (§12).
    app.surface_draw(&a)
    drawn := gfx.grid_snapshot(panel_grid(&a), context.temp_allocator)
    testing.expect(t, strings.contains(drawn, "kind"), drawn)

    // --- unload, and the ledger ---
    testing.expect(t, app.plug_unload(&a, app.plug_find(&a, "example")))
    _, still_named := app.kind_named(&a, "example")
    testing.expect(t, !still_named, "the ledger left a kind behind")
    _, still_cmd := app.plug_cmd_named(&a, "example")
    testing.expect(t, !still_cmd, "the ledger left a command behind")
    testing.expect(t, !store.store_is_open(&a.docs, id), "the ledger left a document open")
    // The id stays valid and resolves to nothing. Reusing it would route a keystroke into
    // whoever loaded next, which is the failure a stale handle turns into silent corruption.
    testing.expect_value(t, app.kind_name(&a, kind), "")
    // The written row is the user's file now, but the request died with the plugin: a fresh
    // writeback must not put the row back for a plugin that is gone.
    os.remove(app.binds_path(&a))
    app.binds_sync(&a)
    testing.expect(t, !strings.contains(read_binds(&a), "alt+h"), "a dead request wrote back")
}

// A plugin is a directory and the `.so` inside carries the name. The two things that are not
// plugins are here too: a loose `.so`, which an overlay install leaves behind, and a directory
// with no library in it.
@(test)
autoload_takes_a_directory_and_the_library_inside_it :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-layout")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)

    plugins, _ := filepath.join({a.home.data, app.PLUGIN_DIR}, context.temp_allocator)
    built, read := os.read_entire_file(app.plug_path(&a, "example"), context.temp_allocator)
    testing.expect_value(t, read, nil)
    flat, _ := filepath.join({plugins, "example.so"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(flat, built), nil)
    hollow, _ := filepath.join({plugins, "hollow"}, context.temp_allocator)
    testing.expect_value(t, os.make_directory_all(hollow), nil)

    app.plug_autoload(&a)
    i := app.plug_find(&a, "example")
    if !testing.expect(t, i >= 0, a.message) {
        return
    }
    // The leftover sorts FIRST, so a loader that took both shapes would run the library the
    // last release wrote and refuse this one as already loaded.
    testing.expect_value(t, a.plugs[i].path, app.plug_path(&a, "example"))
    testing.expect(t, !strings.contains(a.message, "hollow"), a.message)
}

// A chord no row claims reaches the plugin, because its descriptor says `input: raw` — the
// same field the terminal uses, and the funnel never learns which kind it is looking at (§5).
@(test)
a_raw_chord_reaches_the_plugin :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-raw")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "example")), a.message) {
        return
    }
    kind, _ := app.kind_named(&a, "example")
    id, _ := app.kind_fresh(&a, kind)
    app.ring_add(&a, id)

    app.handle_chord(&a, chord("AD01")) // `q`, which no surface row claims
    store.store_drain(&a.docs)
    testing.expect(t, strings.contains(doc_text(&a, id), "1 chord(s)"), doc_text(&a, id))

    // Declined, so the kernel keeps it. A plugin that swallowed everything would make the miss
    // rule unobservable, which is the thing §8 exists to prevent.
    app.handle_chord(&a, chord("ESC"))
    store.store_drain(&a.docs)
    testing.expect(t, strings.contains(doc_text(&a, id), "1 chord(s)"), doc_text(&a, id))
}

// §7's "anyone may write anyone's buffer", and §14's question about whether anything has to
// refuse one. Nothing does: a foreign splice lands like any other, the OWNER IS TOLD, and its
// own writes are not reported back to it — which is what stops a plugin that re-reads on
// `moved` from answering itself forever.
@(test)
a_foreign_write_lands_and_the_owner_is_told :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-foreign")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "example")), a.message) {
        return
    }
    kind, _ := app.kind_named(&a, "example")
    id, _ := app.kind_fresh(&a, kind)
    app.ring_add(&a, id)
    app.plug_pump(&a) // the plugin's own `open` write, which it is NOT told about

    // A splice nobody asked the plugin's permission for, the way a formatter would.
    doc := store.store_doc(&a.docs, id)
    txt.doc_apply(doc, {{0, 4, "KIND", 0, 0}})
    store.store_drain(&a.docs)
    app.plug_pump(&a)

    app.handle_chord(&a, chord("AD01")) // makes the plugin redraw its count
    store.store_drain(&a.docs)
    text := doc_text(&a, id)
    testing.expect(t, strings.contains(text, "1 foreign write(s)"), text)
}

// The case the tag exists for: the owner's own submit LOSES the race and is dropped, so the
// generation that moved is somebody else's and the owner has to hear about it. A flag set at
// submit time would swallow this one, which is the moment a plugin most needs to re-read.
@(test)
a_dropped_write_of_our_own_still_reports_the_move :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-lost-race")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "example")), a.message) {
        return
    }
    kind, _ := app.kind_named(&a, "example")
    id, _ := app.kind_fresh(&a, kind)
    app.ring_add(&a, id)
    app.plug_pump(&a)

    // A foreign transaction is QUEUED first and the plugin's own goes on behind it, so the
    // drain applies the foreign one and drops the plugin's whole. (The seam drains behind each
    // call, so this is the shape a lost race has: two writers, one queue, one generation.)
    gen, _ := store.store_gen(&a.docs, id)
    store.store_submit(&a.docs, id, gen, {{0, 4, "KIND", 0, 0}})
    app.handle_chord(&a, chord("AD01")) // the plugin writes, and the drain behind it drops that
    testing.expect(t, strings.contains(doc_text(&a, id), "KIND"), "the foreign write did not land")
    testing.expect(t, !strings.contains(doc_text(&a, id), "1 chord(s)"), "the stale write landed")
    app.plug_pump(&a)

    app.handle_chord(&a, chord("AD01"))
    text := doc_text(&a, id)
    testing.expect(t, strings.contains(text, "1 foreign write(s)"), text)
}

// A registered command is typed exactly the way a builtin is, and it reads the focused
// document through the snapshot it was handed — by pointer, with no call back in (§6).
@(test)
a_registered_command_runs_from_the_command_line :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-command")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "example")), a.message) {
        return
    }
    app.ring_add(&a, scratch_doc(&a, "note", "alpha\nbeta\ngamma"))
    doc := store.store_doc(&a.docs, app.ring_focused(&a).doc)
    doc.cursors[doc.primary] = {anchor = {1, 0}, head = {1, 0}}

    app.cl_exec(&a, ":example")
    testing.expect_value(t, a.message, "beta")
}

// A reload is unload then load, and the two loads never share a Self: a handle kept across one
// carries the wrong generation and is refused rather than honoured.
@(test)
a_reload_refuses_the_handle_the_last_load_had :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-reload")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "example")), a.message) {
        return
    }
    i := app.plug_find(&a, "example")
    stale := app.plug_self(&a, i)

    testing.expect(t, app.plug_reload(&a, "example"), a.message)
    testing.expect_value(t, app.plug_find(&a, "example"), i) // the slot is reused
    testing.expect(t, app.plug_self(&a, i) != stale, "the generation did not move")
}

// The claim §7 makes for `pluginify` being a link step: the helpers a plugin uses INLINE into
// it, and the ones it does not are stripped. Symbols are how that is observable — a helper that
// is still a call is still a symbol.
@(test)
helpers_inline_and_the_rest_are_stripped :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-lto")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    state, out, errs, err := os.process_exec(
        {command = {"nm", app.plug_path(&a, "example")}},
        context.temp_allocator,
    )
    if err != nil || !state.success {
        testing.expectf(t, false, "nm: %v %s", err, string(errs))
        return
    }
    syms := string(out)
    testing.expect(t, strings.contains(syms, "oket_main"), "the entry point is missing")
    // Used, and gone: example.c calls all four, so what is left of them is inlined code.
    for gone in ([?]string{"oket_line_copy", "oket_copy", "oket_run", "oket_set"}) {
        testing.expectf(t, !strings.contains(syms, gone), "%s did not inline", gone)
    }
    // Never called, and gone: nothing declares which helpers it wants, and the linker is what
    // decides. This is the half that would cost a shared library nothing to keep — the whole
    // list core included, which example.c never touches.
    for gone in ([?]string{"oket_word_right", "oket_pair_close", "oket_col_bytes",
                           "oket_list_publish", "oket_cursor_span"}) {
        testing.expectf(t, !strings.contains(syms, gone), "%s was not stripped", gone)
    }
}

// CURSORS.md §7: a dispatch's snapshot names the document's own cursor array. A held snapshot
// copies, because an append moves that array out from under it.
@(test)
a_dispatch_names_the_cursors_it_reads :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !testing.expect(t, ok, "no app") {
        return
    }
    defer close_app(&a)
    id := scratch_doc(&a, "note", "one\ntwo")
    doc := store.store_doc(&a.docs, id)
    txt.doc_add_cursor(doc, txt.Pos{1, 3})

    v := app.view_make(&a, id)
    defer app.view_free(v)
    testing.expect_value(t, rawptr(v.snap.cursors), rawptr(raw_data(doc.cursors[:])))
    testing.expect_value(t, int(v.snap.ncursors), len(doc.cursors))
    testing.expect(t, v.curs == nil, "a dispatch allocated for cursors")

    kept := app.view_hold(&a, id)
    defer app.view_free(kept)
    testing.expect(t, rawptr(kept.snap.cursors) != rawptr(raw_data(doc.cursors[:])),
                   "a held snapshot borrowed an array that will move")
    testing.expect_value(t, int(kept.snap.ncursors), len(doc.cursors))
    testing.expect_value(t, int(kept.snap.cursors[1].head.line), doc.cursors[1].head.line)
}

package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../desc"
import "../gfx"
import "../input"
import "../shape"
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

// --- §8: the seam is a C ABI, not a C-only ABI ---

// Four plugins in four languages, three of which no C compiler saw, loaded side by side into
// one kernel. `stage.sh` picks the toolchain off the extension and `ownplug` brings its own
// recipe; nothing in `plug.odin` or `oket.h` learns which one ran.
//
// Registering is not the whole claim, so every command is CALLED. The answer coming back is
// what proves the seam crossed: helper SOURCES linked into the Zig one, a helper ARCHIVE into
// the Odin and C++ ones, and `ownplug` reaching `message` off the api with no helpers at all.
@(test)
a_plugin_the_c_compiler_never_saw_loads_and_runs :: proc(t: ^testing.T) {
    Lang :: struct {
        name, said: string,
    }
    LANGS :: [?]Lang {
        {"zigplug", "hello from zig"},
        {"odinplug", "hello from odin"},
        {"cppplug", "hello from c++"},
        {"ownplug", "hello from a recipe"},
    }
    a, ok := plug_app(t, "oket-plug-langs", "src/tests/zigplug", "src/tests/odinplug",
                      "src/tests/cppplug", "src/tests/ownplug")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)

    for l in LANGS {
        if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, l.name)), a.message) {
            return
        }
        _, is_cmd := app.plug_cmd_named(&a, l.name)
        testing.expectf(t, is_cmd, ":%s did not register", l.name)
    }
    for l in LANGS {
        app.cl_exec(&a, fmt.tprintf(":%s", l.name))
        testing.expect_value(t, a.message, l.said)
    }
}

// Bare `:pluginify` builds what is focused, and with NOTHING focused it must refuse rather than
// fall through to a default. `filepath.dir("")` answers ".", so a missing guard here builds the
// working directory as if it were a plugin.
@(test)
a_bare_pluginify_with_nothing_focused_refuses :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_app(&a)

    app.cl_exec(&a, ":pluginify")
    // The USAGE line exactly: without the guard it resolves "." instead, gets past this and
    // fails later with a different complaint, which a looser assertion would not tell apart.
    testing.expect_value(t, a.message, app.USAGE_PLUGINIFY)
}

// The other half of bare `:pluginify`: with a source file focused it resolves to the DIRECTORY
// that file is in, which is the plugin. Asked of the resolver directly, because the answer is
// the claim and spawning a compiler to read it back would test the compiler.
@(test)
a_bare_pluginify_resolves_the_focused_file_to_its_plugin :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-pluginify-focus", "plugins/edit")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    app.plug_autoload(&a) // `edit` is what opens a file at all

    src, _ := filepath.join({REPO, "plugins", "example", "example.c"}, context.temp_allocator)
    raw, _ := filepath.join({REPO, "plugins", "example"}, context.temp_allocator)
    dir, _ := filepath.clean(raw, context.temp_allocator)
    if !testing.expect(t, app.args_open(&a, {src}), a.message) {
        return
    }

    got, flags := app.pluginify_target(&a, "")
    testing.expect_value(t, got, dir)
    testing.expect_value(t, flags, "")

    // A flag alone is still not a directory, so the focused file answers and the flag survives.
    got, flags = app.pluginify_target(&a, "--asan")
    testing.expect_value(t, got, dir)
    testing.expect_value(t, flags, "--asan")

    // Named beats focused.
    got, _ = app.pluginify_target(&a, "plugins/fold")
    testing.expect_value(t, got, "plugins/fold")
}

// stage.sh refuses what it cannot build, rather than picking one and going quiet. Two arms, and
// both fixtures are made here: a directory that exists only to fail does not belong in the tree.
@(test)
stage_refuses_two_languages_and_no_source :: proc(t: ^testing.T) {
    dir, ok := scratch(t, "oket-stage-refuse")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    script, _ := filepath.join({REPO, "plugins", "stage.sh"}, context.temp_allocator)
    out, _ := filepath.join({dir, "out"}, context.temp_allocator)

    run :: proc(script, src, out: string) -> bool {
        state, _, _, err := os.process_exec({command = {script, src, out}},
                                            context.temp_allocator)
        return err == nil && state.success
    }

    // No source of any kind, and no build.sh either.
    empty, _ := filepath.join({dir, "empty"}, context.temp_allocator)
    testing.expect_value(t, os.make_directory_all(empty), nil)
    testing.expect(t, !run(script, empty, out), "an empty directory built")

    // Two toolchains in one folder is a build system, not a plugin.
    both, _ := filepath.join({dir, "both"}, context.temp_allocator)
    testing.expect_value(t, os.make_directory_all(both), nil)
    for name in ([?]string{"both.c", "both.zig"}) {
        f, _ := filepath.join({both, name}, context.temp_allocator)
        testing.expect_value(t, os.write_entire_file(f, transmute([]u8)string("")), nil)
    }
    testing.expect(t, !run(script, both, out), "two languages built")
}

// The one thing that crosses the seam as a RAW BYTE. `oket_span.attrs` is a uint8_t in C and a
// `shape.Attrs` in Odin, and nothing at runtime checked the two agreed — the `#assert`s in
// shape.odin pin the Odin side only. So a plugin writes OKET_ATTR_BOLD and the renderer is
// asked what it got.
@(test)
a_plugins_attribute_bits_are_the_renderers :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-plug-attrs", "src/tests/cppplug")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    app.plug_autoload(&a)

    id := scratch_doc(&a, "bold.txt", "abcdef")
    app.ring_add(&a, id)
    app.cl_exec(&a, ":cppbold")
    testing.expect_value(t, a.message, "")

    snap := store.store_snapshot(&a.docs, id)
    defer txt.snapshot_release(snap)
    drawn := app.doc_styles(&a, id, nil, &snap.text, nil, 0, 1)
    if !testing.expect(t, len(drawn) > 0, "the publish reached nothing") {
        return
    }
    testing.expect_value(t, drawn[0].attrs, gfx.Attrs{.Bold})
}

// --- the seam's two declarations ---

// `oket.h` and `shape` state the same constants in two languages, and until this nothing tied
// them: the `#assert`s in shape.odin pin the ODIN side, and oket.h's `_Static_assert`s pin
// struct SIZES, so a value added or reordered on one side was a silent divergence.
//
// Every enum `shape` owns, read out of the header by name. Adding a member on the Odin side and
// forgetting the header fails here, which a hand-written pair list would not have caught.
@(test)
the_c_header_and_shape_agree_on_every_value :: proc(t: ^testing.T) {
    Group :: struct {
        type:   typeid,
        prefix: string,
        bit:    bool, // the C constant is `1 << ordinal`, not the ordinal
    }
    GROUPS :: [?]Group {
        {shape.Render, "OKET_RENDER_", false},
        {shape.Wrap, "OKET_WRAP_", false},
        {shape.Numbers, "OKET_NUMBERS_", false},
        {shape.Align, "OKET_ALIGN_", false},
        {shape.Follow, "OKET_FOLLOW_", false},
        {shape.Input, "OKET_INPUT_", false},
        {shape.Mouse, "OKET_MOUSE_", false},
        {shape.Selection, "OKET_SELECT_", false},
        {shape.Style, "OKET_TOK_", false},
        {shape.Attr, "OKET_ATTR_", true},
        {shape.Chan, "OKET_SET_", true},
    }

    path, _ := filepath.join({REPO, "src", "plug", "oket.h"}, context.temp_allocator)
    raw, err := os.read_entire_file(path, context.temp_allocator)
    if !testing.expect_value(t, err, nil) {
        return
    }
    header := string(raw)

    for g in GROUPS {
        names := reflect.enum_field_names(g.type)
        values := reflect.enum_field_values(g.type)
        for name, i in names {
            spelled := strings.concatenate(
                {g.prefix, strings.to_upper(name, context.temp_allocator)},
                context.temp_allocator,
            )
            want := i64(values[i])
            if g.bit {
                want = 1 << uint(want)
            }
            got, held := c_constant(header, spelled)
            if !testing.expectf(t, held, "%s is not in oket.h", spelled) {
                continue
            }
            testing.expectf(t, got == want, "%s is %d in oket.h and %d in shape",
                            spelled, got, want)
        }
    }

    // Not an enum member, so the loop above cannot reach it: the id every interned token sits
    // above, which is the count of the base vocabulary.
    base, held := c_constant(header, "OKET_TOKEN_BASE")
    testing.expect(t, held, "OKET_TOKEN_BASE is not in oket.h")
    testing.expect_value(t, base, i64(len(shape.Style)))
}

// The value oket.h gives a constant. Only an occurrence followed by `=` counts, so the name
// mentioned in a comment is not the one read.
@(private = "file")
c_constant :: proc(header, name: string) -> (value: i64, ok: bool) {
    rest := header
    for {
        at := strings.index(rest, name)
        if at < 0 {
            return 0, false
        }
        rest = rest[at + len(name):]
        eq := strings.trim_left_space(rest)
        if !strings.has_prefix(eq, "=") {
            continue // a mention, not a definition
        }
        expr := strings.trim_left_space(eq[1:])
        // The whole value, up to whatever ends it inside an enum body.
        if cut := strings.index_any(expr, ",}\n/"); cut >= 0 {
            expr = expr[:cut]
        }
        expr = strings.trim_space(expr)
        // `1 << N` or a plain integer, which is every form the header uses.
        if shift := strings.index(expr, "<<"); shift >= 0 {
            n := strconv.parse_i64(strings.trim_space(expr[shift + 2:])) or_return
            return 1 << uint(n), true
        }
        return strconv.parse_i64(expr)
    }
}

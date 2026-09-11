package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../desc"
import "../store"
import app "../oket"

// The themer (plugins/themer): rows from the platter and the cache, and the two chains a bind
// stages. The stage mode itself is binds_file_test's; what is gated here is that each row
// carries the chain its state means — and that a hand-made file never grows an `rm`.

@(private = "file")
themes_write :: proc(dir, file, body: string) {
    path, _ := filepath.join({dir, file}, context.temp_allocator)
    _ = os.write_entire_file(path, transmute([]u8)body)
}

// A home with a themes directory in a known state: gruvbox hand-made, dracula pulled (file AND
// manifest line), nord and zenburn one curl away. The cache is present, so no fetch spawns and
// the gate needs no network.
@(private = "file")
themer_app :: proc(t: ^testing.T, name: string) -> (a: app.App, dir: string, ok: bool) {
    a = plug_app(t, name, "plugins/themer") or_return
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "themer")), a.message) {
        close_plug_app(&a)
        return {}, "", false
    }
    dir, _ = filepath.join({home_dir(a.home), "themes"}, context.temp_allocator)
    os.make_directory(dir)
    themes_write(dir, "gruvbox.toml", "\"ui.text\" = \"#ebdbb2\"\n")
    themes_write(dir, "dracula.toml", "\"ui.text\" = \"#f8f8f2\"\n")
    themes_write(dir, ".themer", "dracula\n")
    themes_write(dir, ".list", "dracula\nnord\nzenburn\n")
    app.cl_exec(&a, fmt.tprintf(":th.dir %s", dir))
    app.cl_exec(&a, ":ring themer")
    if !testing.expect(t, app.ring_focused(&a) != nil, a.message) {
        close_plug_app(&a)
        return {}, "", false
    }
    return a, dir, true
}

// THE GATE. Line 1 is the head; line 0 is the filter; the rows sort here-first, then by name: dracula, gruvbox,
// nord, zenburn.
@(test)
each_row_carries_the_chain_its_state_means :: proc(t: ^testing.T) {
    a, _, ok := themer_app(t, "oket-themer-rows")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    text := doc_text(&a, id)
    testing.expect(t, strings.contains(text, "2 here of 4"), text)
    testing.expect(t, strings.contains(text, "* dracula"), text)
    testing.expect(t, strings.contains(text, "pulled"), text)
    testing.expect(t, strings.contains(text, "* gruvbox"), text)

    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)

    act, _ := desc.field_of(d, 2, "act") // dracula is here: a bare switch
    testing.expect_value(t, act.value, ":set theme.name dracula")
    rm, _ := desc.field_of(d, 2, "rm") // and pulled: the one kind of row del may remove
    testing.expect(t, strings.contains(rm.value, "rm '"), rm.value)
    testing.expect(t, strings.contains(rm.value, "dracula.toml"), rm.value)
    testing.expect(t, strings.contains(rm.value, ":set theme.name gruvbox"), rm.value)
    testing.expect(t, strings.contains(rm.value, ".themer"), rm.value)

    act2, _ := desc.field_of(d, 3, "act") // gruvbox is here but hand-made: switch only
    testing.expect_value(t, act2.value, ":set theme.name gruvbox")
    rm2, held := desc.field_of(d, 3, "rm") // NO removal: an empty span fills an empty hole
    testing.expect(t, held && rm2.value == "" && rm2.lo == rm2.hi, "a hand-made file grew an rm")

    act3, _ := desc.field_of(d, 4, "act") // nord is a curl away: pull, manifest, switch, done
    testing.expect(t, strings.contains(act3.value, "curl -fsSL"), act3.value)
    testing.expect(t, strings.contains(act3.value, "nord.toml"), act3.value)
    testing.expect(t, strings.contains(act3.value, ".themer"), act3.value)
    testing.expect(t, strings.contains(act3.value, ":set theme.name nord"), act3.value)
    testing.expect(t, strings.contains(act3.value, ":th.done"), act3.value)
}

// The staged chains end in `:th.done`, and this is what it does: the platter moved under the
// list, so the list says so — a removal's row loses its star and keeps its place in the cache.
@(test)
th_done_rereads_the_platter :: proc(t: ^testing.T) {
    a, dir, ok := themer_app(t, "oket-themer-done")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    path, _ := filepath.join({dir, "dracula.toml"}, context.temp_allocator)
    os.remove(path)
    themes_write(dir, ".themer", "")
    app.cl_exec(&a, ":th.done")

    text := doc_text(&a, app.ring_focused(&a).doc)
    testing.expect(t, !strings.contains(text, "* dracula"), text)
    testing.expect(t, strings.contains(text, "dracula"), text) // still one curl away: the cache lists it
    testing.expect(t, strings.contains(text, "1 here of 4"), text)
}

// The filter is the bytes typed NOW, not every byte ever typed: backspace must widen the match
// set when the shorter filter matches more rows.
@(test)
backspace_widens_the_filter :: proc(t: ^testing.T) {
    a, _, ok := themer_app(t, "oket-themer-filter")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    app.handle_chord(&a, chord("AC04", {.Ctrl})) // ctrl+f arms the filter
    app.text_input(&a, 'n')
    app.text_input(&a, 'o')
    testing.expect(t, strings.contains(doc_text(&a, id), "1 shown"), doc_text(&a, id)) // nord
    app.handle_chord(&a, chord("BKSP"))
    text := doc_text(&a, id)
    testing.expect(t, strings.contains(text, "2 shown"), text) // `n`: nord and zenburn
}

// A manifest line whose file is gone marks nothing: `pulled` must mean there is a file to
// remove, so a stale line cannot hand `del` an rm for a path that is not there.
@(test)
a_stale_manifest_line_marks_nothing :: proc(t: ^testing.T) {
    a, dir, ok := themer_app(t, "oket-themer-stale")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    themes_write(dir, ".themer", "dracula\nnord\n") // nord's file was never pulled
    app.cl_exec(&a, ":th.done")

    d := store.store_descriptor(&a.docs, app.ring_focused(&a).doc)
    defer desc.release(d)
    rm, held := desc.field_of(d, 3, "rm") // nord's row
    testing.expect(t, held && rm.value == "", "a stale manifest line grew an rm")
}

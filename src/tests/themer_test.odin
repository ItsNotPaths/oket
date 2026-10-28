package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../desc"
import "../store"
import app "../oket"

// The themer (plugins/themer): rows from the platter and the cache, and the chain a bind stages.
// The stage mode itself is binds_file_test's; what is gated here is that each row carries the
// chain its state means — and that `th.rm` never takes a hand-made file.

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

    act, _ := field_at(&a, id, 2, "act") // dracula is here: a bare switch
    testing.expect_value(t, act.value, ":set theme.name dracula")
    name, _ := field_at(&a, id, 2, "name") // what `del` hands th.rm
    testing.expect_value(t, name.value, "dracula")

    act2, _ := field_at(&a, id, 3, "act") // gruvbox is here but hand-made
    testing.expect_value(t, act2.value, ":set theme.name gruvbox")

    act3, _ := field_at(&a, id, 4, "act") // nord is a curl away: pull, manifest, switch, done
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

// `th.rm` takes a pulled theme's file and its manifest line, and nothing else: a hand-made file
// shares no provenance with the list, so it stays.
@(test)
th_rm_removes_only_what_was_pulled :: proc(t: ^testing.T) {
    a, dir, ok := themer_app(t, "oket-themer-rm")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    gruvbox, _ := filepath.join({dir, "gruvbox.toml"}, context.temp_allocator)
    dracula, _ := filepath.join({dir, "dracula.toml"}, context.temp_allocator)
    manifest, _ := filepath.join({dir, ".themer"}, context.temp_allocator)

    app.cl_exec(&a, ":th.rm gruvbox")
    testing.expect(t, os.exists(gruvbox), "th.rm took a hand-made file")

    app.cl_exec(&a, ":th.rm dracula")
    testing.expect(t, !os.exists(dracula), "th.rm left the pulled file")
    body, _ := os.read_entire_file(manifest, context.temp_allocator)
    testing.expect(t, !strings.contains(string(body), "dracula"), string(body))
    testing.expect(t, strings.contains(doc_text(&a, app.ring_focused(&a).doc), "1 here of 4"))
}

// A manifest line whose file is gone marks nothing: `pulled` must mean there is a file to
// remove, so a stale line cannot make `th.rm` act on a path that is not there.
@(test)
a_stale_manifest_line_marks_nothing :: proc(t: ^testing.T) {
    a, dir, ok := themer_app(t, "oket-themer-stale")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    themes_write(dir, ".themer", "dracula\nnord\n") // nord's file was never pulled
    app.cl_exec(&a, ":th.done")
    app.cl_exec(&a, ":th.rm nord")
    testing.expect(t, strings.contains(a.message, "was not pulled"), a.message)
}

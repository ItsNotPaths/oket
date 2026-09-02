package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"
import app "../oket"

// Stage 11's gate (§13): a 1 MB cold parse never drops a frame below 60.
//
// The subject is plugins/syntax over a real tree-sitter grammar. vendor/tree-sitter-json is the
// one that is vendored, and only for this — a gate may not depend on the network, so the
// grammar is built here by the same script a user runs.
//
// What is really being asked is whether a plugin that DRAWS NOTHING and OPENS NOTHING can be
// reached at all, and whether work too big for one frame can be spread over several without a
// thread. Both answers are one rule: a `moved` handler that returns non-zero is called again.

// A frame at 60 Hz. The parse budget inside the plugin sits well under it, and this is what the
// whole dispatch is measured against.
@(private = "file")
FRAME :: 16 * time.Millisecond

@(private = "file")
syntax_app :: proc(t: ^testing.T, name: string) -> (a: app.App, ok: bool) {
    a = plug_app(t, name, "plugins/syntax") or_return
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "syntax")), a.message) {
        close_plug_app(&a)
        return {}, false
    }
    // The grammar, built the way a user builds one: `tools/oket-grammar <name> <repo-or-dir>`,
    // pointed at the vendored checkout so the gate needs no network.
    dir, _ := filepath.join({a.home, "grammars"}, context.temp_allocator)
    script, _ := filepath.join({REPO, "tools", "oket-grammar"}, context.temp_allocator)
    src, _ := filepath.join({REPO, "vendor", "tree-sitter-json"}, context.temp_allocator)
    env := fmt.tprintf("OKET_GRAMMARS=%s", dir)
    state, _, errs, err := os.process_exec(
        {command = {script, "json", src}, env = {env, "PATH=/usr/bin:/bin"}},
        context.temp_allocator,
    )
    if err != nil || !state.success {
        testing.expectf(t, false, "oket-grammar json: %v %s", err, string(errs))
        close_plug_app(&a)
        return {}, false
    }
    // Where to look. The plugin's own answer is beside the binary, which in a test is the test
    // runner — so the gate says it rather than moving the binary.
    app.cl_exec(&a, fmt.tprintf(":grammar dir %s", dir))
    if !testing.expect(t, strings.contains(a.message, dir), a.message) {
        close_plug_app(&a)
        return {}, false
    }
    return a, true
}

// One frame of the kernel's loop, as main.odin runs it: settle, then tell whoever moved. The
// return is the latch — somebody is mid-parse and the next frame is its next slice.
//
// CPU time on this thread, not wall clock. The claim is that a frame's WORK fits in a frame,
// and the runner puts 32 tests on a box with fewer cores than that — a wall clock here measures
// how oversubscribed the machine is. What the plugin yields on is still monotonic, because a
// frame the user waits through is wall clock however it was spent.
@(private = "file")
frame :: proc(a: ^app.App) -> (latched: bool, took: time.Duration) {
    start := cpu_now()
    app.docs_settle(a)
    latched = app.plug_pump(a)
    app.surface_draw(a)
    return latched, cpu_now() - start
}

@(private = "file")
cpu_now :: proc() -> time.Duration {
    ts: posix.timespec
    posix.clock_gettime(.THREAD_CPUTIME_ID, &ts)
    return time.Duration(ts.tv_sec) * time.Second + time.Duration(ts.tv_nsec)
}

@(private = "file")
json_doc :: proc(a: ^app.App, text: string) -> store.Id {
    id := scratch_doc(a, "conf.json", text)
    app.ring_add(a, id)
    app.surface_draw(a) // the body rectangle, so there is a viewport to draw against
    return id
}

// Every layer's runs over the whole document, out of the store.
@(private = "file")
all_styles :: proc(a: ^app.App, id: store.Id) -> []store.Span {
    return store.store_spans(&a.docs, id, 0, max(int))
}

// The gate's first half: a plugin with no kind and no surface colours a file it never opened,
// and the colour reaches the screen through the renderer everything else goes through.
@(test)
a_grammar_colours_a_file_it_never_opened :: proc(t: ^testing.T) {
    a, ok := syntax_app(t, "oket-syntax-gate")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := json_doc(&a, `{"name": 12}`)
    for _ in 0 ..< 4 {
        frame(&a)
    }

    spans := all_styles(&a, id)
    if !testing.expect(t, len(spans) >= 2, "the parse published nothing") {
        return
    }
    // `"name"` is a key and `12` is a number: two capture names, two interned tokens, two
    // colours the plugin never chose. It publishes names; the palette decides.
    key := spans[0]
    num := spans[len(spans) - 1]
    testing.expect_value(t, key.lo, 1)
    testing.expect_value(t, key.hi, 7)
    testing.expect_value(t, num.lo, 9)
    testing.expect_value(t, num.hi, 11)
    testing.expect(t, key.fg != a.theme[.Fg], "the key took the plain foreground")
    testing.expect(t, num.fg != key.fg, "a number and a string key must not be one colour")

    // And through the one renderer: the cell under `1` of `12` carries the number's colour.
    app.surface_draw(&a)
    cell := gfx.grid_at(&a.grid, 9 + gutter(&a, id), 0)
    if testing.expect(t, cell != nil, "nothing was drawn") {
        testing.expect_value(t, cell.fg, num.fg)
    }
}

// The line-number gutter the scratch document draws, which is what the cells above sit past.
@(private = "file")
gutter :: proc(a: ^app.App, id: store.Id) -> int {
    snap := store.store_snapshot(&a.docs, id)
    defer txt.snapshot_release(snap)
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    return view.gutter_width(&snap.text, d)
}

// THE GATE. A megabyte of JSON, parsed from cold, and no frame goes past 16 ms. The parse does
// not fit in one — that is the point — so it says so and resumes, and the loop stays live
// because plug_pump said somebody was mid-slice.
@(test)
a_cold_parse_of_a_megabyte_never_drops_a_frame :: proc(t: ^testing.T) {
    a, ok := syntax_app(t, "oket-syntax-budget")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := json_doc(&a, big_json(1 << 20))
    worst, frames := time.Duration(0), 0
    latched := true
    for latched && frames < 4096 {
        took: time.Duration
        latched, took = frame(&a)
        worst = max(worst, took)
        frames += 1
    }

    frame(&a) // the last slice's publish is pending until the next drain, like every write

    testing.expectf(t, frames > 1, "a megabyte parsed in one frame; the gate proves nothing")
    testing.expectf(t, !latched, "the parse never finished in %d frames", frames)
    testing.expectf(t, worst < FRAME, "the worst frame took %v, past a 60 Hz frame", worst)
    testing.expect(t, len(all_styles(&a, id)) > 0, "it finished and published nothing")
}

// A document with no language is not work, and saying so must cost nothing: the watcher sees
// every open document, and a terminal, a listing and the command line are most of them.
@(test)
a_document_with_no_grammar_is_left_alone :: proc(t: ^testing.T) {
    a, ok := syntax_app(t, "oket-syntax-quiet")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := scratch_doc(&a, "notes.wat", "{\"a\": 1}")
    app.ring_add(&a, id)
    latched, _ := frame(&a)
    testing.expect(t, !latched, "a document with no grammar latched anyway")
    testing.expect_value(t, len(all_styles(&a, id)), 0)
}

// A grammar built while oket is running is picked up by the chain that built it, which is the
// whole of §7's "composition is a config line": a shell step, then a plugin command.
@(test)
a_grammar_that_arrives_late_is_picked_up_by_the_chain :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-syntax-late", "plugins/syntax")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "syntax")), a.message) {
        return
    }
    dir, _ := filepath.join({a.home, "grammars"}, context.temp_allocator)
    _ = os.make_directory(dir)
    app.cl_exec(&a, fmt.tprintf(":grammar dir %s", dir))

    id := json_doc(&a, `{"a": 1}`)
    for _ in 0 ..< 3 {
        frame(&a)
    }
    testing.expect_value(t, len(all_styles(&a, id)), 0) // no grammar, no colours, no complaint

    script, _ := filepath.join({REPO, "tools", "oket-grammar"}, context.temp_allocator)
    src, _ := filepath.join({REPO, "vendor", "tree-sitter-json"}, context.temp_allocator)
    state, _, errs, err := os.process_exec(
        {command = {script, "json", src},
         env = {fmt.tprintf("OKET_GRAMMARS=%s", dir), "PATH=/usr/bin:/bin"}},
        context.temp_allocator,
    )
    if !testing.expectf(t, err == nil && state.success, "%v %s", err, string(errs)) {
        return
    }
    // The second half of the chain, and the only part the seam knows about.
    app.cl_exec(&a, ":grammar ready json")
    testing.expect(t, strings.contains(a.message, "ready"), a.message)
    for _ in 0 ..< 3 {
        frame(&a)
    }
    testing.expect(t, len(all_styles(&a, id)) > 0, "the late grammar never coloured anything")
}

// --- fixtures ---

// Roughly `size` bytes of JSON with enough strings and numbers in it to make a query do work.
@(private = "file")
big_json :: proc(size: int) -> string {
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "[\n")
    for i := 0; strings.builder_len(b) < size; i += 1 {
        if i > 0 {
            strings.write_string(&b, ",\n")
        }
        fmt.sbprintf(&b, `  {{"id": %d, "name": "row %d", "on": true, "tags": ["a", "b"]}}`, i, i)
    }
    strings.write_string(&b, "\n]\n")
    return strings.to_string(b)
}

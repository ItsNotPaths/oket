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
    dir, _ := filepath.join({a.home.data, "grammars"}, context.temp_allocator)
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
    // Where to look. The plugin's own answer is the data directory, which in a test is the test
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

// Every publisher's runs over the whole document, in the order this document ranks them.
@(private = "file")
all_styles :: proc(a: ^app.App, id: store.Id) -> []store.Span {
    return store.store_spans(&a.docs, id, 0, max(int), app.spans_order(a, id))
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
    testing.expect(t, key.fg != u32(gfx.Token.Fg), "the key took the plain foreground")
    testing.expect(t, num.fg != key.fg, "a number and a string key must not be one token")

    // And through the one renderer: the cell under `1` of `12` carries the number token's
    // colour, resolved where every style value is — at the draw.
    app.surface_draw(&a)
    cell := gfx.grid_at(panel_grid(&a), 9 + gutter(&a, id), 0)
    if testing.expect(t, cell != nil, "nothing was drawn") {
        testing.expect_value(t, cell.fg, app.token_color(&a, u16(num.fg)))
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

// A plugin is a directory, so what is not source rides in it. This plugin links tree-sitter and
// the release ships the RECIPE rather than the archive, so losing the carry would ship a syntax
// plugin nobody can rebuild.
@(test)
the_build_carries_what_is_not_source :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-syntax-carry", "plugins/syntax")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    beside := filepath.dir(app.plug_path(&a, "syntax")) // a slice of the path
    recipe, _ := filepath.join({beside, "get-tree-sitter"}, context.temp_allocator)
    testing.expect(t, os.exists(recipe), recipe)
    // build.flags is a build input, not data, and has no business beside the library.
    flags, _ := filepath.join({beside, "build.flags"}, context.temp_allocator)
    testing.expect(t, !os.exists(flags), flags)
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
    dir, _ := filepath.join({a.home.data, "grammars"}, context.temp_allocator)
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

// --- the grammar list ---

// Three hundred languages as a DOCUMENT (§5, §11): the rows are text the kernel draws, point
// IS the selection, and `enter` is a binds.conf row carrying the registry entry into a shell
// step. No widget, no key handler of its own, and nothing in the plugin spawns anything.

// The list, opened the way anything of a plugin's kind is: a lane (§5). A plugin cannot open a
// document — there is no message for it — and `:ring` already answers the question.
@(private = "file")
list_open :: proc(t: ^testing.T, a: ^app.App) -> (store.Id, bool) {
    app.cl_exec(a, ":ring grammars")
    app.surface_draw(a)
    s := app.ring_focused(a)
    if !testing.expect(t, s != nil, a.message) {
        return {}, false
    }
    kind, registered := app.kind_named(a, "grammars")
    if !testing.expect(t, registered, "nothing registered the grammars kind") {
        return {}, false
    }
    testing.expect_value(t, app.doc_kind(a, s.doc), kind)
    return s.doc, true
}

@(private = "file")
lines_of :: proc(a: ^app.App, id: store.Id) -> []string {
    return strings.split_lines(doc_text(a, id), context.temp_allocator)
}

// How many separate lit runs the bar holds. One is a block crossing; two is the same block
// wrapped around both ends at once.
@(private = "file")
lit_runs :: proc(row: string) -> int {
    runs, inside := 0, false
    for r in row {
        switch r {
        case '\u2588':
            if !inside {
                runs += 1
            }
            inside = true
        case '\u2591':
            inside = false
        }
    }
    return runs
}

// The row for one grammar, by the name in its own column.
@(private = "file")
row_named :: proc(a: ^app.App, id: store.Id, name: string) -> string {
    want := fmt.tprintf(" %s ", name) // the marker, then the name's own column
    for row in lines_of(a, id) {
        if len(row) > 1 && strings.has_prefix(row[1:], want) {
            return row
        }
    }
    return ""
}

@(private = "file")
type_text :: proc(a: ^app.App, text: string) {
    for r in text {
        app.text_input(a, r)
    }
}

// The row point is on, which is the only selection this document has.
@(private = "file")
row_at_point :: proc(a: ^app.App, id: store.Id) -> string {
    s := app.ring_focused(a)
    rows := lines_of(a, id)
    line := s.view.point.head.line
    return line >= 0 && line < len(rows) ? rows[line] : ""
}

@(test)
the_grammar_list_is_a_document_of_rows :: proc(t: ^testing.T) {
    a, ok := syntax_app(t, "oket-grammars-list")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id, opened := list_open(t, &a)
    if !opened {
        return
    }
    rows := lines_of(&a, id)
    testing.expectf(t, len(rows) > 100, "a registry of %d rows is not a registry", len(rows))
    testing.expect(t, strings.contains(rows[0], "installed"), rows[0])

    // The gate built json into this directory, so its row is the one that is marked. Every
    // other row is a language you could have, drawn the same and starred when you do.
    marked, plain := 0, 0
    for row in rows[1:] {
        if strings.has_prefix(row, "*") {
            marked += 1
            testing.expect(t, strings.contains(row, "json"), row)
        } else {
            plain += 1
        }
    }
    testing.expect_value(t, marked, 1)
    testing.expect(t, plain > 100, "nothing was listed as missing")
}

// ctrl+f takes the typing into the filter: the document takes runes so they REACH the plugin
// (§5), and while the filter is armed what a keystroke moves is which rows there are, never
// the text. The same chord, the same verbs and the same head line as every other list.
@(test)
typing_into_the_list_filters_it :: proc(t: ^testing.T) {
    a, ok := syntax_app(t, "oket-grammars-filter")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id, opened := list_open(t, &a)
    if !opened {
        return
    }
    whole := len(lines_of(&a, id))

    app.handle_chord(&a, chord("AC04", {.Ctrl})) // ctrl+f arms the filter
    type_text(&a, "rust")
    rows := lines_of(&a, id)
    testing.expectf(t, len(rows) < whole && len(rows) > 1, "%d rows matched `rust`", len(rows) - 1)
    for row in rows[1:] {
        testing.expect(t, strings.contains(row, "rust"), row)
    }
    // Point is put on the first match, because the row it was standing on may not be in the
    // list any more.
    testing.expect(t, strings.contains(row_at_point(&a, id), "rust"), row_at_point(&a, id))

    // An extension is a way in too: `rs` is not a substring of `rust`, and it is what somebody
    // with the file open has to hand. `:gr.clear` disarms the filter, so ctrl+f arms it again.
    app.cl_exec(&a, ":gr.clear")
    app.handle_chord(&a, chord("AC04", {.Ctrl}))
    type_text(&a, "rs")
    found := false
    for row in lines_of(&a, id)[1:] {
        found ||= strings.contains(row, " rust ")
    }
    testing.expect(t, found, "`rs` did not reach the grammar that colours one")

    // Backspace takes a rune off it and esc drops it, both through rows the plugin ASKED for.
    app.handle_chord(&a, chord("BKSP"))
    testing.expect(t, strings.contains(lines_of(&a, id)[0], "/r"), lines_of(&a, id)[0])
    app.handle_chord(&a, chord("ESC"))
    testing.expect(t, !a.quit, "esc quit oket instead of clearing the filter")
    testing.expect_value(t, len(lines_of(&a, id)), whole)

    // Backspace with nothing typed is a no-op, not a size_t underflow.
    app.handle_chord(&a, chord("BKSP"))
    testing.expect_value(t, len(lines_of(&a, id)), whole)
}

// THE ROW IS THE INSTALL. Four holes over one row, filled from fields the plugin published, so
// the whole of what it takes to build a grammar is a line in binds.conf — and a rev or a
// subpath the registry does not carry fills as an EMPTY argument rather than as the row's name.
@(test)
a_row_carries_its_whole_registry_entry :: proc(t: ^testing.T) {
    a, ok := syntax_app(t, "oket-grammars-row")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    _, opened := list_open(t, &a)
    if !opened {
        return
    }
    app.handle_chord(&a, chord("AC04", {.Ctrl})) // ctrl+f, then the filter
    type_text(&a, "rust") // the first match, and point is on it

    line, filled := app.bind_expand(&a, "oket-grammar <lang> <repo> <rev> <sub>")
    if !testing.expect(t, filled, a.message) {
        return
    }
    testing.expect(t, strings.has_prefix(line,
                   "oket-grammar rust https://github.com/tree-sitter/tree-sitter-rust "), line)
    testing.expect(t, strings.has_suffix(line, " ''"), line)
    testing.expect_value(t, len(strings.fields(line, context.temp_allocator)), 5)

    // The row the plugin actually asked for, read back off the request list rather than typed
    // in again here: three steps, and the shell one is `|| true` so the LAST always runs. A
    // chain that stopped on a failure would leave the bar running with nothing behind it.
    asked := ""
    for r in a.reqs {
        if r.ctx == "grammars" && r.chord == "enter" {
            asked = r.line
        }
    }
    if !testing.expect(t, asked != "", "nothing asked for enter over the grammar list") {
        return
    }
    line, filled = app.bind_expand(&a, strings.trim_prefix(asked, "exec "))
    if !testing.expect(t, filled, a.message) {
        return
    }
    // Through cl_parse rather than the raw split: `||` is a step operator, so `|| true` is
    // its own segment until the coalesce puts it back inside the shell step.
    app.cl_parse(&a, line)
    steps := a.chain.steps
    if !testing.expect_value(t, len(steps), 3) {
        return
    }
    testing.expect(t, strings.contains(steps[0].text, "gr.build rust"), steps[0].text)
    testing.expect(t, strings.has_suffix(strings.trim_space(steps[1].text), "|| true"),
                   steps[1].text)
    testing.expect(t, strings.contains(steps[2].text, "grammar ready rust"), steps[2].text)
}

// A BUILD IS A CHAIN, and the row is what says one is out. The first step marks it and the bar
// starts moving; the last step stats the platter, so the word the row ends on is what is there
// and not what the chain managed to reach.
@(test)
a_building_row_says_so_and_ends_on_the_platter :: proc(t: ^testing.T) {
    a, ok := syntax_app(t, "oket-grammars-build")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id, opened := list_open(t, &a)
    if !opened {
        return
    }

    // A name the registry does not carry is one no shell step should be spawned for, so the
    // first step of the chain refuses and nothing after it runs.
    app.cl_exec(&a, ":gr.build nosuchlanguage")
    testing.expect(t, strings.contains(a.message, "nosuchlanguage"), a.message)

    app.cl_exec(&a, ":gr.build rust")
    row := row_named(&a, id, "rust")
    testing.expect(t, strings.contains(row, "building"), row)
    testing.expect(t, strings.contains(row, "\u2588"), row)

    // The frames the bar moves on come from the watcher's latch. Nothing else would wake the
    // loop while a shell step is out, and a bar nobody redraws says nothing.
    latched, _ := frame(&a)
    testing.expect(t, latched, "a build left the list with nothing to move its bar")

    // A whole lap, sampled: the lit part is ONE run at every step of it. Wrapping the run over
    // the bar's own width puts a piece at each end at once, which reads as two blocks bouncing.
    // It moves on a WALL CLOCK, so the lap takes the same time whatever the frame rate is.
    moved, laps := false, 0
    for i := 0; i < 100; i += 1 {
        time.sleep(15 * time.Millisecond)
        frame(&a)
        bar := row_named(&a, id, "rust")
        testing.expectf(t, lit_runs(bar) <= 1, "the lit part broke in two: %s", bar)
        laps += lit_runs(bar)
        moved ||= bar != row
    }
    testing.expect(t, moved, "the bar never moved")
    testing.expect(t, laps > 0, "the bar was never lit")

    // A second build while one is out is refused HERE, not four steps later inside the kernel
    // with nothing on screen to say why.
    app.cl_exec(&a, ":gr.build json")
    testing.expect(t, strings.contains(a.message, "still building"), a.message)

    // rust never landed, so the row says so — and the step reports the same to the chain.
    app.cl_exec(&a, ":grammar ready rust")
    row = row_named(&a, id, "rust")
    testing.expect(t, strings.contains(row, "failed"), row)
    testing.expect(t, !strings.contains(row, "\u2588"), row)
    latched, _ = frame(&a)
    testing.expect(t, !latched, "the bar is still asking for frames after it stopped")

    // json IS on the platter, so the same last step reads it as a build that worked.
    app.cl_exec(&a, ":gr.build json")
    app.cl_exec(&a, ":grammar ready json")
    row = row_named(&a, id, "json")
    testing.expect(t, strings.has_prefix(row, "*") && strings.contains(row, "done"), row)

    // Going back to browsing takes the word off: it answered the keystroke that asked for the
    // build, and the filter moving is the next one.
    app.handle_chord(&a, chord("AC04", {.Ctrl}))
    type_text(&a, "j")
    row = row_named(&a, id, "json")
    testing.expect(t, !strings.contains(row, "done"), row)
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

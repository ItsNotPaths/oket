package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../desc"
import "../gfx"
import "../store"
import "../txt"
import "../view"
import app "../oket"

// VIEWS.md stage 7's gate, and it is a DESIGN gate: a fold plugin and a popup plugin, ordered by
// a config line, both real. If a stage could not be expressed as edits against what it was
// handed, the model in §5 would be redesigned rather than patched.
//
// The subjects are plugins/fold and plugins/popup, built by plugins/stage.sh like any other. The
// question each test asks is whether a view is EDITS: whether a document derived from a stage's
// output draws, moves and saves as the document it came from, and whether a stage that reads
// what the user sees can be written without reaching around the pipeline.

@(private = "file")
BLOCK :: "def one():\n    alpha\n    beta\ndef two():\n    gamma\n"

// The same, with something for the completion stage to find: `gam` on the last line carries on
// into `gamma_ray` on the first.
@(private = "file")
WORDS :: "gamma_ray = 1\ndef one():\n    alpha\n    beta\ndef two():\n    gam\n"

// The editor, the two stages, and a config line ordering them. The line is written before the
// plugins load, so nothing here depends on what request_config would have added.
@(private = "file")
views_app :: proc(
    t: ^testing.T,
    name, text: string,
    // The `view` line the file starts with. "" leaves config.conf absent, so the stages write
    // their own row the way a first load does; "none" writes the owner markers alone, which is
    // the file saying both have been offered and neither is wanted.
    order := "fold, popup",
) -> (
    a: app.App,
    path: string,
    ok: bool,
) {
    a = plug_app(t, name, "plugins/edit", "plugins/fold", "plugins/popup") or_return
    if order != "" {
        conf, _ := filepath.join({a.home.config, app.CONFIG_NAME}, context.temp_allocator)
        body := order != "none" \
            ? fmt.tprintf("[edit]\nview = %s\n", order) \
            : "# --- fold ---\n# --- popup ---\n"
        if err := os.write_entire_file(conf, transmute([]u8)body); err != nil {
            testing.expectf(t, false, "cannot write %s: %v", conf, err)
            close_plug_app(&a)
            return {}, "", false
        }
    }
    app.plug_init(&a)
    app.config_sync(&a)
    for plugin in ([?]string{"edit", "fold", "popup"}) {
        if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, plugin)), a.message) {
            close_plug_app(&a)
            return {}, "", false
        }
    }
    path, _ = filepath.join({home_dir(a.home), "note.py"}, context.temp_allocator)
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
    app.surface_draw(&a) // the body rectangle, so a viewport and a pane width exist
    return a, path, true
}

// What is DRAWN, as one string. Nothing else in the kernel builds this: the renderer walks the
// derived text a row at a time, and a test wants the whole of it.
@(private = "file")
drawn :: proc(a: ^app.App, id: store.Id) -> string {
    t, _ := app.views_of(a, id)
    if t == nil {
        return doc_text(a, id) // no stage had anything to say, so it is the document itself
    }
    b := strings.builder_make(context.temp_allocator)
    for line in 0 ..< txt.text_line_count(t) {
        if line > 0 {
            strings.write_byte(&b, '\n')
        }
        strings.write_bytes(&b, txt.text_line(t, line, context.temp_allocator))
    }
    return strings.to_string(b)
}

// The caret, put on a line by the kernel's own motion, which is the only way a document is
// navigated (§4).
@(private = "file")
go_line :: proc(a: ^app.App, line: int) {
    app.point_move(a, .Doc_Start, false)
    // Down until it arrives, not `line` times: a hidden run is stepped over as one move, so a
    // fold above the target would otherwise carry the caret past it.
    for _ in 0 ..< 64 {
        if point(a).head.line >= line {
            break
        }
        app.point_move(a, .Down, false)
    }
}

// --- the fold half: a stage that reads the source ---

// The shape in one pass. A stage returns edits, the kernel derives a piece table from them, and
// what comes back is an ordinary document the one renderer draws — while the document being
// edited has not moved a byte.
@(test)
a_fold_is_edits_against_what_the_stage_was_handed :: proc(t: ^testing.T) {
    a, path, ok := views_app(t, "oket-views-fold", BLOCK)
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    testing.expect_value(t, drawn(&a, id), BLOCK) // nothing is folded yet, so there is no chain
    go_line(&a, 0)
    app.cl_exec(&a, ":fold")
    app.docs_settle(&a)

    testing.expect_value(t, drawn(&a, id), "def one(): ⋯ 2 lines\ndef two():\n    gamma\n")
    // AND THE DOCUMENT HAS NOT MOVED. A view edit is never submitted, so the text, the file and
    // the journal have never heard of a fold (§6).
    testing.expect_value(t, doc_text(&a, id), BLOCK)
    app.cl_exec(&a, ":w")
    raw, _ := os.read_entire_file(path, context.temp_allocator)
    testing.expect_value(t, string(raw), BLOCK)
}

// §7: the pipeline's only export to motion is the list of runs no cell stands for. `down` off
// the header lands on the next VISIBLE line, and the two lines under it are not landed on.
@(test)
motion_steps_over_what_a_stage_hid :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-motion", BLOCK)
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    go_line(&a, 0)
    app.cl_exec(&a, ":fold")
    app.docs_settle(&a)
    testing.expect(t, len(app.views_hidden(&a, id)) == 1, "the fold exported no hidden run")

    app.point_move(&a, .Down, false)
    testing.expect_value(t, point(&a).head.line, 3) // lines 1 and 2 are not on screen
    app.point_move(&a, .Up, false)
    testing.expect_value(t, point(&a).head.line, 0)
}

// A stage is in a pipeline because a CONFIG LINE says so, never because its plugin loaded. With
// no line, the same loaded plugin is never called and the document is its own view.
@(test)
a_stage_with_no_config_line_is_not_in_the_pipeline :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-unnamed", BLOCK, "none")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    go_line(&a, 0)
    app.cl_exec(&a, ":fold")
    app.docs_settle(&a)
    tx, dv := app.views_of(&a, id)
    testing.expect(t, tx == nil && dv == nil, "a stage no config line names built a view")
    testing.expect_value(t, drawn(&a, id), BLOCK)
}

// The plugin going away takes its view with it, and the document it derived is still there. A
// chain is a name in a file resolving to a live plugin, so an unload is a name that stops
// resolving rather than a document left half-derived.
@(test)
unloading_a_stage_leaves_the_document_it_derived :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-unload", BLOCK)
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    go_line(&a, 0)
    app.cl_exec(&a, ":fold")
    app.docs_settle(&a)
    testing.expect(t, strings.contains(drawn(&a, id), "⋯"), drawn(&a, id))

    app.plug_unload(&a, app.plug_find(&a, "fold"))
    app.docs_settle(&a)
    testing.expect_value(t, drawn(&a, id), BLOCK)
    testing.expect_value(t, len(app.views_hidden(&a, id)), 0)
}

// --- the popup half: a stage that reads the view so far ---

// THE GATE. A popup is positioned against what the user sees. The box goes under the caret's row
// on SCREEN, which a fold above the caret has moved — and the stage does no mapping to get that
// right, because the snapshot it was handed is already the folded document.
@(test)
a_popup_lands_under_the_row_on_screen :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-popup", WORDS)
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    go_line(&a, 5) // `    gam`, with a two-line block above it
    app.handle_chord(&a, chord("END"))
    app.cl_exec(&a, ":complete")
    app.docs_settle(&a)

    // Unfolded, the caret's row is the fifth and the box is the row after it.
    open := strings.split_lines(drawn(&a, id), context.temp_allocator)
    testing.expect_value(t, caret_row(open), 5)
    testing.expect(t, strings.contains(open[6], "gamma_ray"), drawn(&a, id))

    // Now fold the block above. The caret has not moved in the DOCUMENT — it is still on line 5
    // — but the row it is drawn on is two higher, and the box follows the ROW. Nothing in the
    // stage maps a coordinate to get that right: it read the folded snapshot it was handed.
    go_line(&a, 1)
    app.cl_exec(&a, ":fold")
    go_line(&a, 5)
    app.handle_chord(&a, chord("END"))
    app.docs_settle(&a)

    folded := strings.split_lines(drawn(&a, id), context.temp_allocator)
    testing.expect_value(t, caret_row(folded), 3)
    testing.expect(t, strings.contains(folded[4], "gamma_ray"), drawn(&a, id))
    testing.expect_value(t, point(&a).head.line, 5)
}

// The drawn row showing the caret's line, which is what a popup is positioned by.
@(private = "file")
caret_row :: proc(lines: []string) -> int {
    for l, i in lines {
        if strings.has_suffix(l, "gam") {
            return i
        }
    }
    return -1
}

// What the popup puts in is not enterable and not editable: it is a stage's insertion, so the
// map answers the real byte beside it and `:w` never sees it (§6).
@(test)
what_a_stage_inserted_is_not_in_the_document :: proc(t: ^testing.T) {
    a, path, ok := views_app(t, "oket-views-insert", WORDS)
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    go_line(&a, 5)
    app.handle_chord(&a, chord("END"))
    app.cl_exec(&a, ":complete")
    app.docs_settle(&a)

    tx, dv := app.views_of(&a, id)
    if !testing.expect(t, tx != nil, "the popup built no view") {
        return
    }
    // The first byte of the box, mapped back: no original byte stands for it, and the answer is
    // where the original resumes — the end of the line the box was hung under.
    box := txt.text_line_start(tx, 6)
    src, on := view.src_off(dv, box)
    testing.expect(t, !on, "a byte the stage inserted claimed to be in the document")
    testing.expect_value(t, src, len(WORDS) - 1)

    app.cl_exec(&a, ":w")
    raw, _ := os.read_entire_file(path, context.temp_allocator)
    testing.expect_value(t, string(raw), WORDS)
}

// Accepting is an ORDINARY submit against the document, in original coordinates. Nothing the
// stage drew is involved, and the popup closes because the generation moved under it.
@(test)
accepting_a_completion_is_an_ordinary_edit :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-accept", "gamma_ray = 1\nga\n")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    go_line(&a, 1)
    app.handle_chord(&a, chord("END"))
    app.cl_exec(&a, ":complete")
    app.docs_settle(&a)
    testing.expect(t, strings.contains(drawn(&a, id), "gamma_ray"), drawn(&a, id))

    app.cl_exec(&a, ":complete accept")
    app.docs_settle(&a)
    testing.expect_value(t, doc_text(&a, id), "gamma_ray = 1\ngamma_ray\n")
    tx, _ := app.views_of(&a, id)
    testing.expect(t, tx == nil, "the popup outlived the edit it made")
}

// --- the config grammar ---

// A plugin ASKS for its row and the file decides from then on, which is the rule request_bind
// already follows one file over (§7). The two stages join ONE list, in the order they asked.
@(test)
a_stage_asks_for_its_row_once :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-request", BLOCK, "")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    path, _ := filepath.join({a.home.config, app.CONFIG_NAME}, context.temp_allocator)
    raw, _ := os.read_entire_file(path, context.temp_allocator)
    body := string(raw)
    testing.expect(t, strings.contains(body, "view = fold, popup"), body)
    named := app.config_names(&a.config, "edit", "view")
    testing.expect_value(t, len(named), 2)
    testing.expect_value(t, strings.join(named, ",", context.temp_allocator), "fold,popup")

    // The marker is the record that it was asked, so a name the user then deletes stays
    // deleted. Loading again writes nothing.
    edited, _ := strings.replace_all(body, "view = fold, popup", "view = popup",
                                     context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(path, transmute([]u8)edited), nil)
    app.config_sync(&a)
    after, _ := os.read_entire_file(path, context.temp_allocator)
    testing.expect_value(t, string(after), edited)
}

// --- the latch, and a stage that dies ---

// A document in a kind whose `view` line names the boom fixture. Nothing of boom's own is
// opened: a stage runs over somebody else's documents, which is the point of it being config.
@(private = "file")
sliced_app :: proc(t: ^testing.T, name: string) -> (a: app.App, id: store.Id, ok: bool) {
    a = plug_app(t, name, "src/tests/boom") or_return
    conf, _ := filepath.join({a.home.config, app.CONFIG_NAME}, context.temp_allocator)
    body := fmt.tprintf("[%s]\nview = boom\n", app.kind_name(&a, app.KIND_HOME))
    if err := os.write_entire_file(conf, transmute([]u8)body); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", conf, err)
        close_plug_app(&a)
        return {}, {}, false
    }
    app.plug_init(&a)
    app.config_sync(&a)
    if !testing.expect(t, app.fault_install(), "the fault net did not install") ||
       !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "boom")), a.message) {
        close_plug_app(&a)
        return {}, {}, false
    }
    id = store.store_open(&a.docs, "alpha\n")
    gen, _ := store.store_gen(&a.docs, id)
    d := desc.new_from({kind = app.KIND_HOME, ctx = .Text, editable = true, tab_width = 4})
    store.store_submit(&a.docs, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&a.docs)
    app.ring_add(&a, id)
    app.surface_draw(&a)
    return a, id, true
}

// "Not finished, call me again next frame", which is the meaning `Event_Fn`'s return already
// carries for a watcher (§5). What the stage emitted this time is drawn; the settle after it
// asks again, with no generation and no caret having moved.
@(test)
a_stage_that_latches_is_called_again :: proc(t: ^testing.T) {
    a, id, ok := sliced_app(t, "oket-views-latch")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    // Running the command is itself a settle, so the stage has been called once by the time
    // this returns and what it emitted is already what would be drawn.
    app.cl_exec(&a, ":slice 2")
    testing.expect(t, strings.contains(drawn(&a, id), "[2]"), drawn(&a, id))
    testing.expect(t, app.docs_settle(&a), "a stage that answered non-zero did not latch")
    testing.expect(t, strings.contains(drawn(&a, id), "[1]"), drawn(&a, id))
    // The call that answers zero is the last. Nothing after it rebuilds, so the frame loop is
    // free to idle again.
    testing.expect(t, !app.docs_settle(&a), "a settled stage went on asking for frames")
    testing.expect(t, strings.contains(drawn(&a, id), "[0]"), drawn(&a, id))
    testing.expect(t, !app.docs_settle(&a), "a settled chain was rebuilt with nothing moved")
}

// A stage is plugin code, so it goes through the one door (§10): it dies alone, its plugin is
// named and unloaded, and the document it was deriving is the document again.
@(test)
a_stage_that_faults_dies_alone :: proc(t: ^testing.T) {
    a, id, ok := sliced_app(t, "oket-views-fault")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.cl_exec(&a, ":slice 1")
    testing.expect(t, strings.contains(drawn(&a, id), "[1]"), drawn(&a, id))

    app.cl_exec(&a, ":boomview")
    app.docs_settle(&a)
    testing.expect(t, app.plug_find(&a, "boom") < 0, "the plugin outlived its stage's fault")
    testing.expect(t, strings.contains(app.bar_text(&a), "boom"), app.bar_text(&a))
    tx, _ := app.views_of(&a, id)
    testing.expect(t, tx == nil, "the chain outlived the stage that built it")
}

// CURSORS.md §6, through a plugin that computes its own motion: the runs no cell stands for
// cross the seam on the snapshot, so the editor's own `left` and `right` step OVER a fold the
// way the kernel's do. Without that list a plugin's only view is the original text, and one
// press would leave the caret inside a fold nobody can see.
@(test)
a_plugins_own_motion_steps_over_what_a_stage_hid :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-plugin-motion", BLOCK)
    if !ok {
        return
    }
    defer close_plug_app(&a)

    id := app.ring_focused(&a).doc
    go_line(&a, 0)
    app.cl_exec(&a, ":fold")
    app.docs_settle(&a)
    testing.expect(t, len(app.views_hidden(&a, id)) == 1, "the fold exported no hidden run")

    // The end of the header row, which is the run's FAR edge: both edges draw at the same cell,
    // and the direction of travel picks between them (§7).
    app.handle_chord(&a, chord("END"))
    testing.expect_value(t, point(&a).head, txt.Pos{2, 8})
    // One press, whatever the run swallowed — two lines here — because a fold has no inside to
    // sit in. The plugin computed both of these out of `snapshot.hidden`.
    app.handle_chord(&a, chord("RGHT"))
    testing.expect_value(t, point(&a).head, txt.Pos{3, 0})
    app.handle_chord(&a, chord("LEFT"))
    testing.expect_value(t, point(&a).head, txt.Pos{0, 10})
}

// The one renderer draws the derived document, and every consumer of §6 reads it in the right
// space: the row's text is the stage's, and the NUMBER beside it is the line being edited. A
// gutter that counted drawn rows would say 1, 2, 3 over a fold and be lying about all three.
@(test)
the_renderer_draws_the_derived_document :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-draw", BLOCK)
    if !ok {
        return
    }
    defer close_plug_app(&a)

    go_line(&a, 0)
    app.cl_exec(&a, ":fold")
    app.docs_settle(&a)
    app.surface_draw(&a)

    grid := gfx.grid_snapshot(panel_grid(&a), context.temp_allocator)
    testing.expect(t, strings.contains(grid, "def one(): ⋯ 2 lines"), grid)
    // 1, then 4: the numbers belong to the document, and the fold took two rows out between
    // them. A publisher's colours are read in the same space, which is what stops a span
    // measured over line 4 painting the marker on line 1.
    testing.expect(t, strings.contains(grid, "4 def two():"), grid)
}

// A chord is REQUESTED, never claimed (§8), so a row whose key is already taken is written
// commented out with a note — and a stage whose verbs have no key is a stage nobody can reach.
// This is what says the four rows the two plugins ask for are actually live.
@(test)
both_stages_get_the_chords_they_asked_for :: proc(t: ^testing.T) {
    a, _, ok := views_app(t, "oket-views-binds", BLOCK)
    if !ok {
        return
    }
    defer close_plug_app(&a)

    // The PHYSICAL spelling, which is what describe prints and what a row is written as: a
    // position on the keyboard, not what the key types on this layout.
    rows := read_binds(&a)
    for want in ([?]string{"alt+@AB01 = fold", "alt+shift+@AB01 = fold none",
                           "alt+@AB10 = complete", "alt+shift+@AB10 = complete accept"}) {
        // The leading newline is what says the row is LIVE: a chord already taken is written
        // as `# <chord> = <line>   # taken by ...` and the feature has no key at all.
        live := strings.concatenate({"\n", want}, context.temp_allocator)
        testing.expect(t, strings.contains(rows, live), rows)
    }
    // NEITHER STAGE SHADOWS ANYTHING. A refused chord leaves a verb with no key; a chord that
    // SHADOWS a wider row is worse, because it goes in live and quietly takes that key away
    // inside text documents. The editor's three shadows are deliberate — it is replacing those
    // verbs for its own kind — and a fold or a popup has no business replacing anything.
    for c in a.clashes {
        testing.expectf(t, c.owner != "fold" && c.owner != "popup",
                        "%s asked for %s, which is already %s", c.owner, c.chord, c.held)
    }
}

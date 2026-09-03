package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../input"
import app "../oket"

// PANELS.md stage 5's gate, and it is a DESIGN gate: a HELD CHORD IS A ROW. Hold tab, press
// enter on a link, steer, let tab go, and the thing opens where you steered. If any part of
// that had to be code instead of config, the input model would be wrong and the stage stops.
//
// Four claims, and each test below names one:
//   1. `tab` and `tab+enter` are different chords, so nothing is shadowed by holding a key
//   2. describe spells the held chord, because `Chord.held` makes it spellable
//   3. arming is a CONTEXT, so left and right are ordinary rebindable rows while it lasts
//   4. the release runs the line, with `@` resolved to the panel that was steered to

@(private = "file")
TAB :: "TAB"

@(private = "file")
code_of :: proc(name: string) -> input.Code {
    code, _ := input.key_code(name)
    return code
}

// Claim 1. The whole reason tab is safe: the editor's indent row and the picker's row are not
// the same chord, so both can live in the table at once.
@(test)
tab_and_tab_enter_are_different_chords :: proc(t: ^testing.T) {
    binds := app.binds_base()
    defer input.binds_destroy(&binds)

    plain, _, bare := input.bind_lookup(binds[:], chord("RTRN"), .Surface)
    testing.expect(t, bare)
    open, is_open := plain.target.(input.Bind_Line)
    testing.expect(t, is_open)
    testing.expect_value(t, open.mode, input.Bind_Mode.Exec)

    held, _, gestured := input.bind_lookup(binds[:], chord("RTRN", {}, TAB), .Surface)
    testing.expect(t, gestured)
    picker, is_pick := held.target.(input.Bind_Line)
    testing.expect(t, is_pick)
    testing.expect_value(t, picker.mode, input.Bind_Mode.Pick)

    // And tab still types a tab, which is the row an editor shadows for its own indent.
    indent, _, typed := input.bind_lookup(binds[:], chord(TAB), .Text)
    testing.expect(t, typed)
    testing.expect_value(t, indent.target, input.Bind_Target(input.Command.Tab))
}

// Claim 2. A chord that cannot be spelled cannot be a row, so the two spellings both have to
// round-trip: the config one a user types and the physical one describe falls back to.
@(test)
a_held_chord_spells_and_parses_back :: proc(t: ^testing.T) {
    want := input.Chord{code_of("RTRN"), {}, code_of(TAB)}
    parsed, ok := input.chord_parse("tab+enter", nil)
    testing.expect(t, ok)
    testing.expect_value(t, parsed, want)

    phys := input.chord_physical(want, context.temp_allocator)
    testing.expect_value(t, phys, "@TAB+@RTRN")
    again, back := input.chord_parse(phys, nil)
    testing.expect(t, back)
    testing.expect_value(t, again, want)

    testing.expect_value(t, input.chord_format(want, nil, context.temp_allocator), "tab+enter")

    // Two held keys is not a chord: one field holds the key that is down.
    _, two := input.chord_parse("tab+esc+enter", nil)
    testing.expect(t, !two)
}

// Claim 2, the half that matters to a user: describe answers for the gesture, and says it ARMS
// rather than runs.
@(test)
describe_answers_for_a_held_chord :: proc(t: ^testing.T) {
    binds := app.binds_base()
    defer input.binds_destroy(&binds)

    said := input.describe_chord(binds[:], chord("RTRN", {}, TAB), .Surface, nil,
                                 allocator = context.temp_allocator)
    testing.expect(t, strings.has_prefix(said, "tab+enter"), said)
    testing.expect(t, strings.contains(said, "arms"), said)
    testing.expect(t, strings.contains(said, ":open <path> @"), said)
}

// Claim 3, and the step before it: holding the key does NOTHING, because a tab-down is not a
// chord and enters no context. The listing takes no typing, so a tab that reached the document
// would say so.
@(test)
holding_the_key_arms_nothing_and_the_chord_arms :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-pick-arm")
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord(TAB))
    _, early := a.pending.(input.Pending_Pick)
    testing.expect(t, !early)

    app.handle_chord(&a, chord("RTRN", {}, TAB))
    armed, is_armed := a.pending.(input.Pending_Pick)
    testing.expect(t, is_armed)
    testing.expect_value(t, armed.chord.held, code_of(TAB))
    testing.expect_value(t, armed.target, a.focus)
    // Expanded at the PRESS: the hole is already a path, not a `<path>` waiting for one.
    testing.expect(t, strings.has_prefix(armed.line, ":open "), armed.line)
    testing.expect(t, !strings.contains(armed.line, "<path>"), armed.line)
    testing.expect(t, strings.has_suffix(armed.line, " @"), armed.line)
}

// Claim 3. `[pick] left` and `[pick] right` are rows in the table, reached through the ordinary
// dispatch, and the caret follows the target so steering is visible.
@(test)
the_armed_picker_steers_on_rows :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-pick-steer")
    if !ok {
        return
    }
    defer close_app(&a)

    app.panel_open(&a) // two panels, and the focus goes with the new one
    app.panel_step(&a, -1)
    app.handle_chord(&a, chord("RTRN", {}, TAB))

    app.handle_chord(&a, chord("RGHT"))
    armed, _ := a.pending.(input.Pending_Pick)
    testing.expect_value(t, armed.target, 1)
    testing.expect_value(t, app.panel_marked(&a), 1) // the caret is the mark (§3)
    testing.expect_value(t, a.focus, 0) // steering aims the OPEN, never the keys

    // Clamped at both ends: a walk off the strip that made a panel would leave one behind
    // every time the gesture is cancelled. `:np` is how you ask for one on purpose.
    app.handle_chord(&a, chord("LEFT"))
    app.handle_chord(&a, chord("LEFT"))
    armed, _ = a.pending.(input.Pending_Pick)
    testing.expect_value(t, armed.target, 0)

    // And the caret has not moved: while armed, the arrows are the picker's.
    testing.expect_value(t, point(&a).head.line, 0)
}

// Claim 4. The chord again, while armed: there is nowhere to throw this yet, so make somewhere.
// A ROW (`[pick] tab+enter = :np`), so the picker grew no second meaning of its own — and the
// aim goes with the panel, because a target you cannot see is the thing §1 exists to kill.
@(test)
the_chord_again_makes_a_panel_and_steers_to_it :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-pick-np")
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("RTRN", {}, TAB))
    testing.expect_value(t, len(a.panels), 1)

    app.handle_chord(&a, chord("RTRN", {}, TAB))
    armed, still := a.pending.(input.Pending_Pick)
    testing.expect(t, still, "the gesture ended when it should have grown a panel")
    testing.expect_value(t, len(a.panels), 2)
    testing.expect_value(t, armed.target, 1) // the new one, and the caret says so
    testing.expect_value(t, app.panel_marked(&a), 1)
    testing.expect_value(t, a.focus, 0) // the keys never moved: it is the OPEN being aimed
    // The captured line survived the panel, or the release would have nothing to run.
    testing.expect(t, strings.has_prefix(armed.line, ":open "), armed.line)

    // A REPEAT of the same chord is the key never having come up, so it makes nothing.
    app.handle_chord(&a, chord("RTRN", {}, TAB), true)
    testing.expect_value(t, len(a.panels), 2)
}

// The same panel, from the command line, and the same one from `alt+p`: `:np` IS `panel.open`,
// so a strip cannot grow two ways that disagree about where a panel lands.
@(test)
np_is_the_panel_open_verb :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    app.cl_exec(&a, ":np")
    testing.expect_value(t, len(a.panels), 2)
    testing.expect_value(t, a.focus, 1) // unarmed, the aim IS the focus
    app.cl_exec(&a, ":new-panel")
    testing.expect_value(t, len(a.panels), 3)
    testing.expect_value(t, a.focus, 2)
}

// Claim 3, the way out. Escape is a `[pick]` row like the other two, and it runs nothing.
@(test)
escape_drops_the_armed_pick :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-pick-escape")
    if !ok {
        return
    }
    defer close_app(&a)

    app.handle_chord(&a, chord("RTRN", {}, TAB))
    app.handle_chord(&a, chord("ESC"))
    testing.expect(t, a.pending == nil)
    testing.expect(t, !a.quit) // the global quit row is shadowed while the picker is armed
    testing.expect_value(t, len(a.ring.lanes[0].slots), 1) // nothing was opened
}

// Off a link there is nothing to fill the hole with, so the row reports what it cannot do and
// nothing arms — the same answer `exec` gives, at the same moment.
@(test)
a_pick_with_no_field_under_point_arms_nothing :: proc(t: ^testing.T) {
    a, _, ok := listing_app(t, "oket-pick-nolink")
    if !ok {
        return
    }
    defer close_app(&a)

    app.pick_arm(&a, chord("RTRN", {}, TAB), {":open <nowhere> @", .Pick})
    testing.expect(t, a.pending == nil)
    testing.expect(t, strings.contains(a.message, "nowhere"), a.message)

    // And a row bound with no held key cannot arm a gesture nothing would ever finish.
    app.pick_arm(&a, chord("RTRN"), {":open <path> @", .Pick})
    testing.expect(t, a.pending == nil)
    testing.expect(t, strings.contains(a.message, "held key"), a.message)
}

// THE GATE. The whole gesture over a real strip: a listing in panel 1, an editor plugin behind
// `:open`, and a file that lands in panel 2 because that is where the release pointed.
@(test)
hold_steer_release_opens_where_you_steered :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-pick-gate", "plugins/edit")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "edit")), a.message) {
        return
    }

    // One row to steer from, so point is on it with nothing to aim first.
    dir, _ := filepath.join({a.home, "notes"}, context.temp_allocator)
    path, _ := filepath.join({dir, "note.txt"}, context.temp_allocator)
    os.make_directory(dir)
    if err := os.write_entire_file(path, transmute([]u8)string("alpha\n")); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", path, err)
        return
    }
    app.ring_add(&a, listing_doc(&a, dir))
    app.surface_draw(&a)

    app.panel_open(&a)
    app.panel_step(&a, -1)
    app.handle_chord(&a, chord("RTRN", {}, TAB))
    app.handle_chord(&a, chord("RGHT"))

    // Enter comes up before tab, which is how the hand actually leaves the chord: any other
    // release is somebody else's key, and the pick stays armed.
    app.pick_release(&a, code_of("RTRN"))
    _, still := a.pending.(input.Pending_Pick)
    testing.expect(t, still)

    app.pick_release(&a, code_of(TAB))

    testing.expect(t, a.pending == nil)
    testing.expect_value(t, len(a.panels), 2)
    testing.expect_value(t, a.focus, 1) // `@N` aims the keys first, and the open takes them (§11)
    landed := app.panel_slot(&a, app.panel_get(&a, 1))
    if !testing.expect(t, landed != nil, a.message) {
        return
    }
    testing.expect_value(t, app.doc_title(&a, landed.doc), path)
    // And the listing stayed where it was: a pick moves what it opens, nothing else.
    kept := app.panel_slot(&a, app.panel_get(&a, 0))
    testing.expect(t, kept != nil && kept.doc != landed.doc)
}

// The same gate with no panel to steer to: the second `tab+enter` makes one, and the release
// opens into it. This is the gesture from one panel to two without touching `alt+p` first.
@(test)
the_chord_again_makes_the_panel_the_release_opens_into :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-pick-np-gate", "plugins/edit")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "edit")), a.message) {
        return
    }

    dir, _ := filepath.join({a.home, "notes"}, context.temp_allocator)
    path, _ := filepath.join({dir, "note.txt"}, context.temp_allocator)
    os.make_directory(dir)
    if err := os.write_entire_file(path, transmute([]u8)string("alpha\n")); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", path, err)
        return
    }
    app.ring_add(&a, listing_doc(&a, dir))
    app.surface_draw(&a)
    testing.expect_value(t, len(a.panels), 1)

    app.handle_chord(&a, chord("RTRN", {}, TAB))
    app.handle_chord(&a, chord("RTRN", {}, TAB)) // nowhere to throw it, so make somewhere
    app.pick_release(&a, code_of(TAB))

    testing.expect(t, a.pending == nil)
    testing.expect_value(t, len(a.panels), 2)
    landed := app.panel_slot(&a, app.panel_get(&a, 1))
    if !testing.expect(t, landed != nil, a.message) {
        return
    }
    testing.expect_value(t, app.doc_title(&a, landed.doc), path)
}

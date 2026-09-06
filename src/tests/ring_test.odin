package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../input"
import app "../oket"

// Half the gate for build order stage 5: one ring per kind, `alt+N` addressing the lane you are
// looking at, and `` alt+` `` toggling. The other halves are cl_test and chain_test.

@(private = "file")
alt :: proc(name: string) -> input.Chord {
    return chord(name, {.Alt})
}

// `alt+N` is slot N OF THE LANE YOU ARE IN, so two kinds each carry their own 1..N and slot 3
// is never "whichever thing was opened third".
@(test)
alt_n_addresses_the_lane_you_are_in :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 4)
    if !ok {
        return
    }
    defer close_app(&a)

    one := scratch_doc(&a, "one.txt", "one")
    two := scratch_doc(&a, "two.txt", "two")
    app.ring_add(&a, one)
    app.ring_add(&a, two)
    testing.expect_value(t, app.ring_slot(&a), 2)

    // A document of another kind opens in its own lane, at slot 1 of it: the open IS the focus
    // change, so you always see where it went.
    app.ring_add(&a, listing_doc(&a, "."))
    testing.expect_value(t, app.ring_slot(&a), 1)
    testing.expect_value(t, app.kind_name(&a, app.doc_kind(&a, app.ring_focused(&a).doc)), "home")

    // alt+1 in that lane is the listing, not the first text document.
    app.handle_chord(&a, alt("AE01"))
    testing.expect_value(t, app.ring_slot(&a), 1)
    testing.expect_value(t, app.kind_name(&a, app.doc_kind(&a, app.ring_focused(&a).doc)), "home")

    // And alt+2 there opens a SECOND one rather than reaching the text lane's slot 2.
    app.handle_chord(&a, alt("AE02"))
    testing.expect_value(t, app.ring_slot(&a), 2)
    testing.expect_value(t, app.kind_name(&a, app.doc_kind(&a, app.ring_focused(&a).doc)), "home")
}

// Numbered slots exist for muscle memory, and renumbering destroys the one thing they are for.
// A closed slot is a gap; nothing shuffles up into it.
@(test)
a_closed_slot_leaves_a_gap :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 4)
    if !ok {
        return
    }
    defer close_app(&a)

    for name in ([?]string{"a", "b", "c"}) {
        app.ring_add(&a, scratch_doc(&a, name, name))
    }
    app.handle_chord(&a, alt("AE02"))
    testing.expect_value(t, app.ring_slot(&a), 2)

    // Closing hands focus to this lane's alternate, which is the slot alt+2 came from.
    app.handle_chord(&a, alt("AD01")) // alt+q
    testing.expect_value(t, app.ring_slot(&a), 3)
    testing.expect_value(t, app.doc_title(&a, app.ring_focused(&a).doc), "c")

    // 1 is still 1 and 3 is still 3: nothing shuffled up into the gap.
    app.handle_chord(&a, alt("AE01"))
    testing.expect_value(t, app.doc_title(&a, app.ring_focused(&a).doc), "a")
    app.handle_chord(&a, alt("AE03"))
    testing.expect_value(t, app.doc_title(&a, app.ring_focused(&a).doc), "c")

    // alt+2 on the gap opens a fresh document of this lane's KIND, and these documents belong
    // to none: nothing opens, and the slot stays the gap it was. A lane that does name a kind
    // is the test below, where alt+f opens a listing into an empty files lane.
    app.handle_chord(&a, alt("AE02"))
    testing.expect_value(t, app.ring_slot(&a), 3)
}

// The alternate carries most switching on its own, so it crosses lanes: "the thing I was just
// looking at" does not care which ring it was in. The Shift version stays inside one.
@(test)
the_alternate_crosses_lanes_and_the_shift_one_does_not :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 4)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, scratch_doc(&a, "a", "a"))
    app.ring_add(&a, scratch_doc(&a, "b", "b"))
    app.ring_add(&a, listing_doc(&a, "."))

    // alt+` goes back to the text lane's slot 2, across the lane boundary.
    app.handle_chord(&a, alt("TLDE"))
    testing.expect_value(t, app.doc_title(&a, app.ring_focused(&a).doc), "b")

    // alt+shift+` stays here: slot 1 of this lane, not the listing.
    code, _ := input.key_code("TLDE")
    app.handle_chord(&a, {code, {.Alt, .Shift}, 0})
    testing.expect_value(t, app.doc_title(&a, app.ring_focused(&a).doc), "a")
}

// N0 is a reserved SLOT, not a lane and not an exemption a kind asks for: alt+N cannot reach it
// and alt+q cannot close it.
@(test)
the_system_slot_is_outside_the_rotation :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 4)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, scratch_doc(&a, "a", "a"))
    app.sys_println(&a, "hello")

    // Nothing in 1..9 addresses it.
    for name in ([?]string{"AE01", "AE02", "AE09"}) {
        app.handle_chord(&a, alt(name))
        testing.expect(t, app.ring_slot(&a) != app.SLOT_ZERO)
    }

    app.handle_chord(&a, alt("AE10")) // alt+0
    testing.expect_value(t, app.ring_slot(&a), app.SLOT_ZERO)
    testing.expect_value(t, app.bar_text(&a), "N0  the terminal oket runs things in")

    // And it survives a close: its shell is the kernel's, so its jobs get a real session.
    app.handle_chord(&a, alt("AD01"))
    testing.expect_value(t, app.ring_slot(&a), app.SLOT_ZERO)
}

// Switching lanes is its own key, and it is a default ROW naming the kind in a command line —
// so the kind is in config the user can read and never in a case in the dispatch (§5).
@(test)
a_default_row_switches_lanes_by_kind_name :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 4)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, scratch_doc(&a, "a", "a"))

    // alt+t opens the terminal lane even though nothing has been in it: a lane with nothing in
    // it still opens, which is what makes the chord useful before the first session. A KERNEL
    // kind, because `:ring edit` and `:ring files` name kinds a plugin registers and this test
    // loads none — the row is the same shape either way.
    app.handle_chord(&a, alt("AD05"))
    session := app.ring_focused(&a).doc
    testing.expect_value(t, app.kind_name(&a, app.doc_kind(&a, session)), "term")

    app.handle_chord(&a, alt("TLDE")) // alt+`, back to the document we came from
    testing.expect_value(t, app.doc_title(&a, app.ring_focused(&a).doc), "a")

    // And back again, to where that lane was LEFT rather than to a second fresh session.
    app.handle_chord(&a, alt("AD05"))
    testing.expect_value(t, app.ring_focused(&a).doc, session)
}

// A kind is the narrow tier of the bind table: `[home]` beats `[surface]` where it applies,
// which is how one chord means one thing on the home page and another in a listing.
@(test)
a_kind_section_narrows_over_its_context :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close_app(&a)

    app.binds_parse(&a, "[surface]\n@AC03 = exec :ls\n[home]\n@AC03 = exec :open <path>\n",
                    "binds.conf")
    answer := input.describe_chord(a.binds[:], chord("AC03"), .Surface, nil, app.names(&a),
                                   app.KIND_HOME)
    defer delete(answer)
    testing.expect(t, strings.contains(answer, ":open <path>"), answer)
    testing.expect(t, strings.contains(answer, "[home,"), answer)

    // The wider row still answers for a surface that is not this kind.
    wide := input.describe_chord(a.binds[:], chord("AC03"), .Surface, nil)
    defer delete(wide)
    testing.expect(t, strings.contains(wide, ":ls"), wide)
}

// The lane that empties out under you: focus falls to the alternate spot across lanes, and with
// nothing live anywhere the last panel lands on a home page. The kernel screen is a recovery
// floor and alt+q is not the way to it.
@(test)
closing_the_last_slot_lands_on_home :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 4)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, scratch_doc(&a, "a", "a"))
    app.ring_add(&a, listing_doc(&a, "."))

    app.handle_chord(&a, alt("AD01")) // the files lane empties; focus crosses to the text lane
    testing.expect_value(t, app.doc_title(&a, app.ring_focused(&a).doc), "a")

    app.handle_chord(&a, alt("AD01")) // nothing was live anywhere, so a home page opened
    s := app.ring_focused(&a)
    if !testing.expect(t, s != nil, "the last panel was left standing on nothing") {
        return
    }
    testing.expect_value(t, app.kind_name(&a, app.doc_kind(&a, s.doc)), "home")
}

// alt+q takes the PANEL with the slot. A panel whose document you just closed is one you asked
// to be rid of, so it does not go hunting for another document to show — a hunt is how two
// panels end up on one slot, and a live slot is in at most one panel (PANELS.md §2).
@(test)
closing_a_slot_closes_its_panel :: proc(t: ^testing.T) {
    a, ok := bare_app(80, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, scratch_doc(&a, "a", "a"))
    app.panel_open(&a)
    app.ring_add(&a, scratch_doc(&a, "b", "b"))
    testing.expect_value(t, len(a.panels), 2)
    kept := a.panels[0].at

    app.handle_chord(&a, alt("AD01"))
    testing.expect_value(t, len(a.panels), 1)
    testing.expect_value(t, a.panels[0].at, kept) // the panel that stayed kept its own document
    testing.expect_value(t, app.doc_title(&a, app.ring_focused(&a).doc), "a")

    // And the last one standing does not close: it falls, the way it does with no strip at all.
    app.handle_chord(&a, alt("AD01"))
    testing.expect_value(t, len(a.panels), 1)
    testing.expect(t, app.ring_focused(&a) != nil, "the last panel was left standing on nothing")
}

// The viewport is view state and belongs to the slot (§11), so switching away and back does not
// lose where you were reading.
@(test)
a_slot_keeps_its_viewport :: proc(t: ^testing.T) {
    a, ok := bare_app(40, 4)
    if !ok {
        return
    }
    defer close_app(&a)

    app.ring_add(&a, scratch_doc(&a, "long", "1\n2\n3\n4\n5\n6\n7\n8"))
    app.ring_add(&a, scratch_doc(&a, "short", "one"))

    app.handle_chord(&a, alt("AE01"))
    app.scroll_by(&a, 4)
    testing.expect_value(t, app.ring_focused(&a).view.top, 4)

    app.handle_chord(&a, alt("AE02"))
    testing.expect_value(t, app.ring_focused(&a).view.top, 0)
    app.handle_chord(&a, alt("AE01"))
    testing.expect_value(t, app.ring_focused(&a).view.top, 4)
}

// ONE PATH, ONE DOCUMENT. A second `:open` of a file the ring already holds is a MOVE and not a
// second document: two of them would be two undo stacks, two journals under one name, and a save
// from either clobbering the other. The editor is the subject only because `:open` hands a file
// to whoever registers `edit` — what is being asked is the ring's rule, not the plugin's.
@(test)
one_path_is_one_document :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-ring-one-path", "plugins/edit")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "edit")), a.message) {
        return
    }
    note, _ := filepath.join({home_dir(a.home), "note.txt"}, context.temp_allocator)
    other, _ := filepath.join({home_dir(a.home), "other.txt"}, context.temp_allocator)
    for path in ([?]string{note, other}) {
        if err := os.write_entire_file(path, transmute([]u8)string("alpha\n")); err != nil {
            testing.expectf(t, false, "cannot write %s: %v", path, err)
            return
        }
    }

    app.cl_exec(&a, fmt.tprintf(":open %s", note))
    first := app.ring_focused(&a).doc
    testing.expect_value(t, app.ring_slot(&a), 1)
    app.cl_exec(&a, fmt.tprintf(":open %s", other))
    testing.expect_value(t, app.ring_slot(&a), 2)

    // The same file, spelled another way: `./x` and `x` are one file (path_abs), so this lands
    // back on the document that is already open rather than making a third slot.
    app.cl_exec(&a, fmt.tprintf(":open %s/./note.txt", home_dir(a.home)))
    testing.expect_value(t, app.ring_slot(&a), 1)
    testing.expect_value(t, app.ring_focused(&a).doc, first)
    testing.expect(t, app.ring_get(&a, 3) == nil, "a second slot was opened on one file")

    // An explicit `#N` for a document that is already somewhere REPORTS: a slot is where a
    // document went the first time, and moving it silently would leave a memorised number
    // pointing at a gap.
    app.cl_exec(&a, fmt.tprintf(":open %s #3", note))
    testing.expect_value(t, app.ring_slot(&a), 1)
    testing.expect_value(t, app.ring_focused(&a).doc, first)
    testing.expect(t, strings.contains(a.message, "already #1"), a.message)
    testing.expect(t, app.ring_get(&a, 3) == nil, "an aimed slot placed one document twice")
}

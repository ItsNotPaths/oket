package tests

import "core:strings"
import "core:testing"
import "../input"

// Stage 4's mouse half in the input package: a click is a chord like any other, and describe
// answers for one. routing_test.odin has the same gate end to end, through the kernel.

// --- chords ---

@(test)
mouse_chords_spell_and_parse_back :: proc(t: ^testing.T) {
    for spelling, m in input.MOUSE_SPELLING {
        chord := input.Chord{input.mouse_code(m), {}}
        shown := input.chord_format(chord, nil, context.temp_allocator)
        phys := input.chord_physical(chord, context.temp_allocator)
        testing.expect_value(t, shown, spelling)
        // A button has one spelling under every layout, so describe never shows it twice.
        testing.expect_value(t, phys, spelling)

        back, ok := input.chord_parse(spelling, nil)
        testing.expectf(t, ok, "%s does not parse back", spelling)
        testing.expect_value(t, back, chord)

        with_mods, mod_ok := input.chord_parse(
            strings.concatenate({"ctrl+", spelling}, context.temp_allocator),
            nil,
        )
        testing.expect(t, mod_ok)
        testing.expect_value(t, with_mods, input.Chord{input.mouse_code(m), {.Ctrl}})
    }
}

// A mouse code must not collide with a key: the bind table holds one Code space and a collision
// would be two chords silently sharing a row.
@(test)
mouse_codes_sit_above_every_key :: proc(t: ^testing.T) {
    for e in input.KEY_NAMES {
        testing.expectf(t, !input.code_is_mouse(e.code), "@%s lands in the mouse range", e.name)
    }
}

@(test)
describe_answers_for_a_click :: proc(t: ^testing.T) {
    binds := input.binds_default()
    defer input.binds_destroy(&binds)

    // Unbound is not the same as inert: a button chord moves point whether or not a row claims
    // it, and describe must say so rather than call it a no-op.
    click := input.describe_chord(binds[:], {input.mouse_code(.Click), {}}, .Surface, nil)
    defer delete(click)
    testing.expect_value(t, click, "click moves point; nothing further is bound")

    double := input.describe_chord(binds[:], {input.mouse_code(.Double_Click), {}}, .Surface, nil)
    defer delete(double)
    testing.expect_value(
        t,
        double,
        "double-click moves point, then runs select.expand: select what point sits in, at the document's own granularity [surface, kernel default]",
    )

    // The wheel scrolls what is under it and leaves the caret alone, so it says nothing about
    // point.
    wheel := input.describe_chord(binds[:], {input.mouse_code(.Wheel_Up), {}}, .Surface, nil)
    defer delete(wheel)
    testing.expect_value(
        t,
        wheel,
        "wheel-up runs view.scroll_up: scroll the view toward the start; point stays put [global, kernel default]",
    )
}

// The gate's first half. Nothing the kernel binds is special-cased in a switch: every default
// resolves through the same table lookup a config row does, mouse included.
@(test)
every_default_chord_is_a_row :: proc(t: ^testing.T) {
    binds := input.binds_default()
    defer input.binds_destroy(&binds)

    mice := 0
    for b in binds {
        ctx := .Global in b.ctx ? input.Bind_Ctx.Global : ctx_of(b.ctx)
        found, _, ok := input.bind_lookup(binds[:], b.chord, ctx, b.kind)
        testing.expectf(t, ok, "%v resolves to nothing in %v", b.chord, ctx)
        testing.expect_value(t, found.target, b.target)
        if input.code_is_mouse(b.chord.code) {
            mice += 1
        }
    }
    testing.expect(t, mice >= 3, "the mouse defaults are missing from the table")
}

@(private = "file")
ctx_of :: proc(set: input.Bind_Ctxs) -> input.Bind_Ctx {
    for c in input.Bind_Ctx {
        if c in set {
            return c
        }
    }
    return .Global
}

// --- press to chord ---

// Click fires on release, so a drag is a selection sweep and not a click on whatever it ended
// over (§8).
@(test)
a_drag_cancels_the_click :: proc(t: ^testing.T) {
    s: input.Mouse_State

    input.mouse_press(&s, .Click, 4, 2)
    testing.expect(t, !input.mouse_motion(&s, 4, 2), "standing still is not a drag")
    m, fired := input.mouse_release(&s, 4, 2, 0.01)
    testing.expect(t, fired)
    testing.expect_value(t, m, input.Mouse.Click)

    input.mouse_press(&s, .Click, 4, 2)
    testing.expect(t, input.mouse_motion(&s, 9, 2))
    _, dragged := input.mouse_release(&s, 9, 2, 5.01)
    testing.expect(t, !dragged, "a drag must not fire a click where it ended")
}

@(test)
a_second_press_in_the_same_cell_is_a_double_click :: proc(t: ^testing.T) {
    s: input.Mouse_State
    press_release :: proc(s: ^input.Mouse_State, x, y: int, at: f64) -> input.Mouse {
        input.mouse_press(s, .Click, x, y)
        m, _ := input.mouse_release(s, x, y, at)
        return m
    }

    testing.expect_value(t, press_release(&s, 3, 1, 0), input.Mouse.Click)
    testing.expect_value(t, press_release(&s, 3, 1, 0.1), input.Mouse.Double_Click)
    // A third press starts over rather than reading as another double.
    testing.expect_value(t, press_release(&s, 3, 1, 0.2), input.Mouse.Click)
    // Same cell, too late.
    testing.expect_value(t, press_release(&s, 3, 1, 9), input.Mouse.Click)
    // In time, wrong cell.
    testing.expect_value(t, press_release(&s, 8, 1, 9.05), input.Mouse.Click)
}

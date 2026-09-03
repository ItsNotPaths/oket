package tests

import "core:math"
import "core:testing"
import "../strip"

// PANELS.md §9's rule, as a test: the strip is a piece, so this file builds one with a struct
// literal and never reaches for an App. If it ever needs the fixture, the layout has grown a
// dependency on documents and it is not a piece any more.

// Pixels, not modes: a panel that is resizing is between its two modes, so the layout takes
// widths in the unit it answers in. `width_px` is the only place a mode is a number.
@(private = "file")
FULL :: [?]f32{100, 100, 100}

// A strip of one is the whole view, gap or no gap: one-panel mode is a length and not a special
// case (§5), and today's single panel has to land where it always did.
@(test)
a_strip_of_one_is_the_whole_view :: proc(t: ^testing.T) {
    s := strip.Strip {
        view = 100,
        gap  = 10,
    }
    one := [?]f32{strip.width_px(s, .Full)}
    it := strip.span(s, one[:], 0)
    testing.expect_value(t, it.x, f32(0))
    testing.expect_value(t, it.w, f32(100))
}

// Two halves are worth one full: the slots tile the view exactly, and the gap comes out of the
// two panels that meet at it, half each. So both are the same width and neither end is inset.
@(test)
two_halves_tile_the_view_with_one_gap_between :: proc(t: ^testing.T) {
    s := strip.Strip {
        view = 100,
        gap  = 10,
    }
    half := [?]f32{strip.width_px(s, .Half), strip.width_px(s, .Half)}
    a, b := strip.span(s, half[:], 0), strip.span(s, half[:], 1)
    testing.expect_value(t, a, strip.Span{0, 45})
    testing.expect_value(t, b, strip.Span{55, 45})
    testing.expect_value(t, b.x - (a.x + a.w), f32(10)) // one gap, and it is the whole of it
}

// The camera follows focus and moves by the least it can: a panel already on screen does not
// scroll the strip, and neither end can be passed.
@(test)
the_camera_moves_by_the_least_it_can :: proc(t: ^testing.T) {
    s := strip.Strip{view = 100}
    widths := FULL

    testing.expect_value(t, strip.look_at(s, widths[:], 0), f32(0))
    testing.expect_value(t, strip.look_at(s, widths[:], 2), f32(200))

    s.camera = 200
    testing.expect_value(t, strip.look_at(s, widths[:], 2), f32(200)) // already there
    testing.expect_value(t, strip.look_at(s, widths[:], 1), f32(100))

    s.camera = 9999 // past the end, whatever asked for it
    testing.expect_value(t, strip.look_at(s, widths[:], 2), f32(200))
}

// A column number means nothing until this has answered (§7). A pixel in a gap belongs to no
// panel, and so does one past the last.
@(test)
a_pixel_is_in_a_panel_or_in_no_panel :: proc(t: ^testing.T) {
    s := strip.Strip {
        view = 100,
        gap  = 10,
    }
    half := [?]f32{50, 50}
    testing.expect_value(t, strip.hit(s, half[:], 0), 0)
    testing.expect_value(t, strip.hit(s, half[:], 44), 0)
    testing.expect_value(t, strip.hit(s, half[:], 50), -1) // the gap
    testing.expect_value(t, strip.hit(s, half[:], 55), 1)
    testing.expect_value(t, strip.hit(s, half[:], 99), 1)
    testing.expect_value(t, strip.hit(s, half[:], 200), -1)
}

// The strip scrolled: a panel left of the camera draws at a negative origin, which is what the
// clip is for, and the hit test says so rather than folding it onto column 0.
@(test)
a_panel_left_of_the_camera_has_a_negative_origin :: proc(t: ^testing.T) {
    s := strip.Strip {
        view   = 100,
        camera = 200,
    }
    widths := FULL
    testing.expect_value(t, strip.span(s, widths[:], 0), strip.Span{-200, 100})
    testing.expect_value(t, strip.span(s, widths[:], 2), strip.Span{0, 100})
    testing.expect_value(t, strip.hit(s, widths[:], 10), 2)
    testing.expect_value(t, strip.total(s, widths[:]), f32(300))
}

// --- stage 6: motion (§7) ---

// The clock is faked here, and that is the point: the decay takes a dt, so a test drives it and
// no frame has to be waited for.
@(private = "file")
HZ_60 :: f32(1.0 / 60)

@(private = "file")
HZ_144 :: f32(1.0 / 144)

@(private = "file")
TAU :: f32(0.09)

// Monotone, never past the destination, and it ENDS: decay only ever approaches, so half a
// pixel out the destination is assigned and the motion stops. Without that last line the strip
// re-renders forever for motion nobody can see.
@(test)
the_decay_is_monotone_and_snaps :: proc(t: ^testing.T) {
    x, dest := f32(0), f32(1000)
    for _ in 0 ..< 1000 {
        at := strip.approach(x, dest, HZ_60, TAU)
        testing.expect(t, at >= x, "the origin went backwards")
        testing.expect(t, at <= dest, "the origin overshot its destination")
        x = at
        if x == dest {
            break
        }
    }
    testing.expect_value(t, x, dest)

    // And the other way, which is the same arithmetic with the sign flipped.
    x = 1000
    for _ in 0 ..< 1000 {
        at := strip.approach(x, 0, HZ_60, TAU)
        testing.expect(t, at <= x && at >= 0, "the origin left the interval")
        x = at
        if x == 0 {
            break
        }
    }
    testing.expect_value(t, x, f32(0))

    // Inside half a pixel it is already there, whatever the clock says.
    testing.expect_value(t, strip.approach(0, 0.4, HZ_60, TAU), f32(0.4))
    testing.expect_value(t, strip.approach(0, 1000, 0, TAU), f32(0)) // no time, no motion
    testing.expect_value(t, strip.approach(0, 1000, HZ_60, 0), f32(1000)) // tau off, no motion
}

// Step on the CLOCK, not on the frame. The same wall time settles the same at 60 Hz and at 144,
// which the frame-count form does not: it would run 2.4 times faster on the faster screen.
@(test)
the_same_clock_settles_in_the_same_wall_time :: proc(t: ^testing.T) {
    settle :: proc(dt: f32) -> f32 {
        x, secs := f32(1000), f32(0)
        for x != 0 && secs < 10 {
            x = strip.approach(x, 0, dt, TAU)
            secs += dt
        }
        return secs
    }
    slow, fast := settle(HZ_60), settle(HZ_144)
    // Within one frame of the slower clock, which is the whole tolerance a step can leave.
    testing.expectf(t, math.abs(slow - fast) <= HZ_60, "60 Hz settled in %v, 144 Hz in %v",
                    slow, fast)
}

// The camera aims at where it is GOING, and the layout in flight is what is drawn. Both are the
// same strip, one frame apart.
@(test)
the_camera_decays_toward_what_look_at_answered :: proc(t: ^testing.T) {
    s := strip.Strip {
        view = 100,
        tau  = TAU,
    }
    widths := FULL
    s.aim = strip.look_at(s, widths[:], 2)
    testing.expect_value(t, s.aim, f32(200))

    for s.camera != s.aim {
        was := s.camera
        s.camera = strip.approach(s.camera, s.aim, HZ_60, s.tau)
        testing.expect(t, s.camera > was, "the camera stalled")
        // Re-aiming from a camera in flight is idempotent, or the target would creep.
        testing.expect_value(t, strip.look_at(s, widths[:], 2), f32(200))
    }
    testing.expect_value(t, strip.span(s, widths[:], 2), strip.Span{0, 100})
}

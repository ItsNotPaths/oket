package tests

import "core:strings"
import "core:testing"
import "../font"
import "../gfx"
import app "../oket"

// The gate for build order stage 1: the screen is text, so what the kernel draws with zero
// plugins loaded diffs in CI without a golden image or a screenshot.
@(test)
screen_snapshot :: proc(t: ^testing.T) {
    a, ok := gfx.atlas_fallback()
    testing.expect(t, ok)
    defer gfx.atlas_destroy(&a)

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 64, 14))
    defer gfx.grid_destroy(&g)

    app.screen_draw(&g, gfx.DEFAULT_THEME, &a)
    snap := gfx.grid_snapshot(&g)
    defer delete(snap)

    testing.expect_value(
        t,
        snap,
        `
  oket dev

  ! no system font: drawing with the built-in fallback atlas

  ┌─ glyph check ──────────────────┐
  │ the quick brown fox 0123456789 │
  │ ÀÉÎÕÜ ñ ç ß « » ± ÷            │
  │ ─│┌┐└┘├┤┬┴┼ ═║                 │
  │ ░▒▓█▀▄                         │
  └────────────────────────────────┘


`,
    )
}

// Every glyph the screen draws has to be in the fallback, or the first thing a user sees on a
// broken machine is a row of tofu.
@(test)
screen_has_no_tofu :: proc(t: ^testing.T) {
    a, ok := gfx.atlas_fallback()
    testing.expect(t, ok)
    defer gfx.atlas_destroy(&a)

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 64, 14))
    defer gfx.grid_destroy(&g)

    app.screen_draw(&g, gfx.DEFAULT_THEME, &a)
    snap := gfx.grid_snapshot(&g)
    defer delete(snap)

    for r in snap {
        if r == '\n' || r == ' ' {
            continue
        }
        testing.expectf(t, gfx.atlas_slot(&a, r) != 0, "U+%04X is not in the fallback atlas", r)
    }
    testing.expect(t, strings.contains(snap, "oket"))
}

// The grid follows the window: a resize re-fits and the screen still draws inside it. A
// one-cell fit is the smallest there is, and a one-cell grid must not fault.
@(test)
screen_survives_any_fit :: proc(t: ^testing.T) {
    a, ok := gfx.atlas_fallback()
    testing.expect(t, ok)
    defer gfx.atlas_destroy(&a)

    g: gfx.Grid
    defer gfx.grid_destroy(&g)
    for size in ([?][2]int{{1, 1}, {8, 3}, {64, 14}, {200, 60}, {40, 12}}) {
        testing.expect(t, gfx.grid_resize(&g, size.x, size.y))
        app.screen_draw(&g, gfx.DEFAULT_THEME, &a)
    }
}

// The warning line only belongs to the fallback: with a real face it is gone and the layout
// closes over it. Skips on a machine with no fonts.
@(test)
screen_with_fonts_drops_the_warning :: proc(t: ^testing.T) {
    sf, sys_ok := font.system_fixed()
    if !sys_ok {
        return
    }
    defer delete(sf.family)
    defer delete(sf.path)
    f, opened := gfx.face_open(sf.path, 16)
    if !opened {
        return
    }
    faces := make([]gfx.Face, 1)
    faces[0] = f
    a, made := gfx.atlas_make(faces)
    testing.expect(t, made)
    defer gfx.atlas_destroy(&a)

    g: gfx.Grid
    testing.expect(t, gfx.grid_init(&g, 64, 14))
    defer gfx.grid_destroy(&g)

    app.screen_draw(&g, gfx.DEFAULT_THEME, &a)
    snap := gfx.grid_snapshot(&g)
    defer delete(snap)
    testing.expect(t, !strings.contains(snap, "no system font"))
    testing.expect(t, strings.contains(snap, "glyph check"))
}

// On Wayland pacing must come from the event wait, not the swap (main.odin says why); this
// is the whole of that decision.
@(test)
wayland_does_not_pace_on_the_swap :: proc(t: ^testing.T) {
    testing.expect_value(t, app.swap_interval("wayland"), 0)
    testing.expect_value(t, app.swap_interval("x11"), 1)
}

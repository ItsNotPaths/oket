package gfx

import "../shape"

// gfx's name for shape.Style. The theme is where a token becomes a colour, so `Token` is what
// reads right at these call sites; `shape` owns the values, and oket.h asserts against them.
Token :: shape.Style

Theme :: [Token][3]f32

// A style value on its way to the renderer: a token id, or a literal colour with this bit set.
// Only the terminal writes literals — an SGR names a colour and no theme has an opinion about
// it. Everything else names a token and the palette decides at draw time, which is what makes
// a theme switch one palette swap and the next frame.
COLOR_LIT :: u32(1) << 31

color_pack :: proc(c: [3]f32) -> u32 {
    q :: proc(v: f32) -> u32 {return u32(clamp(v, 0, 1) * 255 + 0.5)}
    return COLOR_LIT | q(c.r) << 16 | q(c.g) << 8 | q(c.b)
}

color_unpack :: proc(v: u32) -> [3]f32 {
    return {f32(v >> 16 & 255) / 255, f32(v >> 8 & 255) / 255, f32(v & 255) / 255}
}

// Percent toward black; 0 is the colour itself. Darker is the ONE direction derived colours go,
// which is what keeps the token set at five: a shade needs no theme author to define it.
shade :: proc(c: [3]f32, percent: int) -> [3]f32 {
    return c * (1 - clamp(f32(percent), 0, 100) / 100)
}

// A shade of `Bg`, for the surface the panels sit ON. Derived rather than a sixth token: a
// chrome colour every theme author has to define is the cost the set stays small to avoid
// (PANELS.md §12).
theme_behind :: proc(th: Theme, percent: int) -> [3]f32 {
    return shade(th[.Bg], percent)
}

// Is the ink lighter than the ground. The question a theme answers rather than declares, so a
// theme file grows no `dark = true` row and a palette can be asked to draw the other way round
// (MENU.md §4). Rec. 601 weights, which is enough to order two colours.
theme_dark :: proc(th: Theme) -> bool {
    lum :: proc(c: [3]f32) -> f32 {
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }
    return lum(th[.Bg]) < lum(th[.Fg])
}

// Gruvbox, baked in: the floor under every start, and what a test App with no directories
// draws in. Written as the file's own eighths-of-255 rather than rounded, so parsing the
// `.toml` the binary also carries lands on these exact values (theme.odin, THEME_BAKED).
// The keys are the ones theme.odin resolves — ui.text, ui.background, ui.cursor.primary,
// ui.linenr, error.
DEFAULT_THEME :: Theme {
    .Fg     = {235.0 / 255, 219.0 / 255, 178.0 / 255}, // fg1  #ebdbb2
    .Bg     = {40.0 / 255, 40.0 / 255, 40.0 / 255}, // bg0  #282828
    .Accent = {189.0 / 255, 174.0 / 255, 147.0 / 255}, // fg3  #bdae93
    .Dim    = {102.0 / 255, 92.0 / 255, 84.0 / 255}, // bg3  #665c54
    .Alert  = {251.0 / 255, 73.0 / 255, 52.0 / 255}, // red  #fb4934
}

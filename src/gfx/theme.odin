package gfx

// Style tokens, not colours. A plugin names a token and the theme decides what it looks like;
// a plugin that names an RGB value breaks every theme (§8).
//
// The set stays small on purpose. Every token added is one a theme author has to define and a
// plugin author has to choose between.
Token :: enum u8 {
    Fg,
    Bg,
    Accent,
    Dim,
    Alert,
}

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

// Gruvbox, baked in: the same five keys `themes/gruvbox.toml` resolves to, so a start with no
// theme file looks like a start with one. Values are that file's palette, read through the
// same UI keys theme.odin uses — ui.text, ui.background, ui.cursor.primary, ui.linenr, error.
DEFAULT_THEME :: Theme {
    .Fg     = {0.922, 0.859, 0.698}, // fg1  #ebdbb2
    .Bg     = {0.157, 0.157, 0.157}, // bg0  #282828
    .Accent = {0.741, 0.682, 0.576}, // fg3  #bdae93
    .Dim    = {0.486, 0.435, 0.392}, // bg4  #7c6f64
    .Alert  = {0.984, 0.286, 0.204}, // red  #fb4934
}

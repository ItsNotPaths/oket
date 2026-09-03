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

// A shade of `Bg`, for the surface the panels sit ON. Derived rather than a sixth token: a
// chrome colour every theme author has to define is the cost the set stays small to avoid
// (PANELS.md §12). Percent toward black; 0 is `Bg` itself.
theme_behind :: proc(th: Theme, percent: int) -> [3]f32 {
    return th[.Bg] * (1 - clamp(f32(percent), 0, 100) / 100)
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

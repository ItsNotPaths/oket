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

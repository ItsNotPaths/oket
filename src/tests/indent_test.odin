package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "../gfx"
import app "../oket"

// plugins/indent: a tab's indent draws a line, a space's a dot, and a scope draws a line down
// its opener's column, through blank lines, nested, stopping above the line that closes it.

@(private = "file")
NESTED :: "a:\n    b:\n        c\n\n        d\n    e\nf\n\tg\n"

@(test)
indent_marks_and_scope_guides_draw :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-indent", "plugins/edit", "plugins/indent")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    for plugin in ([?]string{"edit", "indent"}) {
        if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, plugin)), a.message) {
            return
        }
    }
    a.config.marks, a.config.guides = true, true // off by default; a load rereads config
    path, _ := filepath.join({home_dir(a.home), "nest.py"}, context.temp_allocator)
    if err := os.write_entire_file(path, transmute([]u8)string(NESTED)); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", path, err)
        return
    }
    app.surface_fit(&a, 50, 12) // every line on screen at once
    app.cl_exec(&a, fmt.tprintf(":open %s", path))
    // Open, tell the watcher, land its publish, draw it.
    for _ in 0 ..< 3 {
        app.docs_settle(&a)
        app.plug_pump(&a)
        app.surface_draw(&a)
    }

    g := &app.panel_focused(&a).grid
    x0, y0, found := origin(g, 'f', 6)
    if !testing.expect(t, found, "line 6 was not drawn") {
        return
    }
    has :: proc(g: ^gfx.Grid, x, y: int, at: gfx.Attr) -> bool {
        c := gfx.grid_at(g, x, y)
        return c != nil && at in c.attrs
    }

    testing.expect(t, has(g, x0 + 2, y0 + 1, .Dot), "spaces draw dots")
    testing.expect(t, !has(g, x0 + 2, y0 + 1, .Rule))
    testing.expect(t, has(g, x0, y0 + 7, .Rule), "a tab draws a line")

    testing.expect(t, !has(g, x0, y0, .Guide), "an opener is not inside its own scope")
    testing.expect(t, has(g, x0, y0 + 1, .Guide))
    testing.expect(t, has(g, x0, y0 + 3, .Guide), "through a blank line")
    testing.expect(t, has(g, x0 + 4, y0 + 3, .Guide), "nested")
    testing.expect(t, has(g, x0, y0 + 5, .Guide))
    testing.expect(t, !has(g, x0 + 4, y0 + 5, .Guide), "the inner scope stops above its close")
    testing.expect(t, !has(g, x0, y0 + 6, .Guide), "the outer one too")
    testing.expect(t, has(g, x0, y0 + 7, .Guide), "an unclosed scope runs on")
}

// Where line `line`'s text starts, found from the cell its first rune `r` sits in.
@(private = "file")
origin :: proc(g: ^gfx.Grid, r: rune, line: int) -> (x, y: int, ok: bool) {
    for y in 0 ..< g.rows {
        for x in 0 ..< g.cols {
            if c := gfx.grid_at(g, x, y); c != nil && c.r == r {
                return x, y - line, true
            }
        }
    }
    return
}

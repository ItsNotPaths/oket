package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import app "../oket"
import "../menubar"

// `config.conf` is WRITTEN complete from the settings table, so the file is how a user learns
// what there is to set (§4).

@(private = "file")
config_at :: proc(t: ^testing.T, name: string) -> (a: app.App, dir: string, ok: bool) {
    dir = scratch(t, name) or_return
    a = bare_app() or_return
    app.app_home(&a, dir) // owned, the way app_init sets it
    app.config_sync(&a)
    return a, dir, true
}

@(private = "file")
config_text :: proc(a: ^app.App) -> string {
    path, _ := filepath.join({a.home.config, "config.conf"}, context.temp_allocator)
    raw, err := os.read_entire_file(path, context.temp_allocator)
    return err == nil ? string(raw) : ""
}

// The file with `bump` added to every whole-number value.
@(private = "file")
bumped :: proc(text: string, bump: int) -> (body: string, rows: int) {
    b := strings.builder_make(context.temp_allocator)
    rest := text
    for line in strings.split_lines_iterator(&rest) {
        key, sep, value := strings.partition(line, " = ")
        if sep == "" || strings.has_prefix(line, "#") {
            fmt.sbprintf(&b, "%s\n", line)
            continue
        }
        rows += 1
        if n, is_int := strconv.parse_int(strings.trim_space(value), 10); is_int {
            fmt.sbprintf(&b, "%s = %d\n", key, n + bump)
        } else {
            fmt.sbprintf(&b, "%s\n", line)
        }
    }
    return strings.to_string(b), rows
}

// THE DRIFT GATE. Every default the file prints is parsed back and has to land on the value the
// code holds. Without this the written file is prose that slowly stops being true, which is
// worse than no file at all.
@(test)
every_printed_default_is_the_real_one :: proc(t: ^testing.T) {
    a, dir, ok := config_at(t, "oket-conf-defaults")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    text := config_text(&a)
    path, _ := filepath.join({dir, "config.conf"}, context.temp_allocator)
    want := app.config_default()

    // The written file has to read back as the defaults themselves.
    _, rows := bumped(text, 0)
    testing.expect_value(t, rows, 19) // a new setting extends BOTH passes below, and this count
    testing.expect_value(t, len(app.config_missing(&a)), 0)
    testing.expect_value(t, a.config.restore, want.restore)
    testing.expect_value(t, a.config.gap, want.gap)
    testing.expect_value(t, a.config.tau, want.tau)
    testing.expect_value(t, a.config.behind, want.behind)
    testing.expect_value(t, a.config.select, want.select)
    testing.expect_value(t, a.config.split, want.split)
    testing.expect_value(t, a.config.font_px, want.font_px)
    testing.expect_value(t, a.config.wheel, want.wheel)
    testing.expect_value(t, a.config.double_ms, want.double_ms)
    testing.expect_value(t, a.config.switcher, want.switcher)
    testing.expect_value(t, a.config.marks, want.marks)
    testing.expect_value(t, a.config.guides, want.guides)
    testing.expect_value(t, a.config.theme, want.theme) // the printed name reads back as the "" default
    testing.expect_value(t, a.config.browser, want.browser) // likewise the printed command

    // And not one of them was reported as unknown: the block names only real settings. That
    // covers the LIST rows too, which have no Config field to compare — an unrecognised
    // `[menu] palette` would land here as "is not a setting".
    testing.expect_value(t, a.message, "")

    // The list settings, checked through what they drive: they are stored by name rather than
    // parsed into a field, so the printed default is right only if the behaviour is unchanged.
    testing.expect_value(t, app.menu_palette(&a), menubar.Palette.Invert)
    testing.expect_value(t, app.menu_show(&a), menubar.Show.Constant)
    testing.expect(t, app.cl_live_listed(&a, app.LIVE_DEFAULT))

    // The alias row the same way: the printed line has to parse back as the shipped one.
    testing.expect_value(t, app.config_alias_line(&a.config, "panel.equalize"),
                         app.ALIASES_DEFAULT[0].line)

    // Off by one, ON PURPOSE. Every reader's fallback is the default, so a printed number the
    // reader cannot parse would fall back to the right answer above; bumped, it has to ARRIVE
    // bumped, which only a value that parsed and reached its field can do.
    body, _ := bumped(text, 1)
    _ = os.write_entire_file(path, transmute([]u8)body)
    app.config_load(&a)
    testing.expect_value(t, a.config.gap, want.gap + 1)
    testing.expect_value(t, a.config.tau, want.tau + 1)
    testing.expect_value(t, a.config.behind, want.behind + 1)
    testing.expect_value(t, a.config.select, want.select + 1)
    testing.expect_value(t, a.config.font_px, want.font_px + 1)
    testing.expect_value(t, a.config.wheel, want.wheel + 1)
    testing.expect_value(t, a.config.double_ms, want.double_ms + 1)
}

// A start writes the file only when there is none. A row the user deleted stays deleted and is
// reported, with the default still running.
@(test)
a_start_never_rewrites_config_conf :: proc(t: ^testing.T) {
    a, dir, ok := config_at(t, "oket-conf-once")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    path, _ := filepath.join({dir, "config.conf"}, context.temp_allocator)
    _ = os.write_entire_file(path, transmute([]u8)string("[strip]\ngap = 7\n"))
    app.config_sync(&a)

    testing.expect_value(t, config_text(&a), "[strip]\ngap = 7\n")
    testing.expect_value(t, a.config.gap, 7)
    testing.expect_value(t, a.config.tau, app.config_default().tau)
    missing := app.config_missing(&a)
    testing.expect(t, slice.contains(missing, "[strip] tau = 90"), "a deleted row was not reported")
    testing.expect(t, !slice.contains(missing, "[strip] gap = 4"), "a present row was reported")
}

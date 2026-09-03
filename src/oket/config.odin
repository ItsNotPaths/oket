package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../conf"

// `config.conf` (§4): the settings the kernel keeps, in the flat `key = value` format
// `binds.conf` already uses and through the same parser. Both files are ones the kernel WRITES,
// which is what ruled out TOML for either.
//
// A row that names no setting is REPORTED, and the rest of the file still lands. A typo that
// silently does nothing is the failure the input design exists to prevent (§8), and it is the
// rule binds.conf follows for a bad row.
//
// Four settings today, which is §4's tripwire: if this grows nesting, flat keys start encoding
// structure in their names — `lang.odin.tab_width` — and that is a worse TOML. Revisit there.

CONFIG_NAME :: "config.conf" // beside the binary, next to binds.conf

Config :: struct {
    restore: bool, // [session] restore = on — the ring, across restarts (session.odin)
    gap:     int, // [strip] gap = 4 — pixels between two panels (PANELS.md §5, §7)
    behind:  int, // [strip] behind = 12 — percent the surface behind the panels is darkened
    tau:     int, // [strip] tau = 90 — milliseconds the strip's motion decays by 1/e (§7)
}

// The zero value is not the default: a gap of nothing puts two documents against each other.
// A strip of one has no gap in it either way, so this changes nothing until a panel is opened.
GAP_DEFAULT :: 4

// ONE number for the camera and for a panel's width, because they are the same motion in the
// same axis (§11): two panels resizing while the camera follows them would otherwise read as
// two speeds in one gesture. Zero turns the motion off, and everything lands at once.
TAU_DEFAULT :: 90

// A gap should read as depth and not as a hole, so it is `Bg` darkened rather than black.
BEHIND_DEFAULT :: 12

config_default :: proc() -> Config {
    return {gap = GAP_DEFAULT, tau = TAU_DEFAULT, behind = BEHIND_DEFAULT}
}

// A setting is where it is written and what reading it does, so adding one is a field above and
// a row here. The read site parses its own value (§4): the file holds strings.
@(private = "file")
Setting :: struct {
    section: string,
    key:     string,
    read:    proc(c: ^Config, value: string),
}

@(private = "file", rodata)
SETTINGS := [?]Setting {
    {"session", "restore", proc(c: ^Config, value: string) {c.restore = conf_on(value)}},
    {"strip", "gap", proc(c: ^Config, value: string) {c.gap = conf_int(value, GAP_DEFAULT)}},
    {"strip", "tau", proc(c: ^Config, value: string) {c.tau = conf_int(value, TAU_DEFAULT)}},
    {"strip", "behind",
     proc(c: ^Config, value: string) {c.behind = conf_int(value, BEHIND_DEFAULT)}},
}

config_load :: proc(a: ^App) {
    a.config = config_default()
    if a.home == "" {
        return
    }
    path, _ := filepath.join({a.home, CONFIG_NAME}, context.temp_allocator)
    raw, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return
    }
    rows, errs := conf.parse(string(raw))
    for e in errs {
        conf_complain(a, CONFIG_NAME, e.line, e.why)
    }
    for row in rows {
        if !config_set(&a.config, row) {
            conf_complain(a, CONFIG_NAME, row.line,
                          fmt.tprintf("[%s] %s is not a setting", row.section, row.key))
        }
    }
}

@(private = "file")
config_set :: proc(c: ^Config, row: conf.Row) -> bool {
    for s in SETTINGS {
        if s.section == row.section && s.key == row.key {
            s.read(c, row.value)
            return true
        }
    }
    return false
}

// The spellings a flat value file has to take, or a user reads `on` back as false with nothing
// to blame.
conf_on :: proc(value: string) -> bool {
    switch strings.to_lower(strings.trim_space(value), context.temp_allocator) {
    case "on", "true", "yes", "1":
        return true
    }
    return false
}

// A whole number, and the setting's own default for anything else: a value the parser cannot
// read is a row that says what it meant, and silently reading it as zero would not.
conf_int :: proc(value: string, fallback: int) -> int {
    n, ok := strconv.parse_int(strings.trim_space(value), 10)
    return ok && n >= 0 ? n : fallback
}

// One bad row is reported and skipped, never fatal — for both files the kernel reads.
conf_complain :: proc(a: ^App, file: string, line: int, why: string) {
    message_set(a, fmt.tprintf("%s:%d: %s", file, line, why))
}

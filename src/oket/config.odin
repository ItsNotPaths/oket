package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../conf"
import "../txt"

// `config.conf` (§4): the settings the kernel keeps, in the flat `key = value` format
// `binds.conf` already uses and through the same parser. Both files are ones the kernel WRITES,
// which is what ruled out TOML for either.
//
// A row that names no setting is REPORTED, and the rest of the file still lands. A typo that
// silently does nothing is the failure the input design exists to prevent (§8), and it is the
// rule binds.conf follows for a bad row.
//
// Five settings today, which is §4's tripwire: if this grows nesting, flat keys start encoding
// structure in their names — `lang.odin.tab_width` — and that is a worse TOML. Revisit there.

CONFIG_NAME :: "config.conf" // beside the binary, next to binds.conf

Config :: struct {
    restore: bool, // [session] restore = on — the ring, across restarts (session.odin)
    gap:     int, // [strip] gap = 4 — pixels between two panels (PANELS.md §5, §7)
    behind:  int, // [strip] behind = 12 — percent the surface behind the panels is darkened
    tau:     int, // [strip] tau = 90 — milliseconds the strip's motion decays by 1/e (§7)
    split:   txt.Split, // [cursor] split = selections — what cursor.split_lines leaves per line
    // [<kind>] spans = treesitter, lsp, rainbow — who draws over whom, lowest first (§8, §9).
    // A kind and not a document, because the answer is about the vocabulary a kind is written
    // in. A publisher the line does not name draws on top of the ones it does (spans.odin).
    order:   [dynamic]Span_Order,
}

// One kind's z-order, as the file said it. Both strings are owned, because the rows the parser
// hands back point into a file body that is temp-allocated.
Span_Order :: struct {
    kind:  string,
    names: []string,
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
    {"cursor", "split", proc(c: ^Config, value: string) {c.split = conf_split(value)}},
}

config_load :: proc(a: ^App) {
    config_destroy(&a.config)
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

// What the file says this kind's publishers stack in, or nothing said. The order is read per
// drawn document, so a line the file grew since is live at the next frame.
config_spans :: proc(c: ^Config, kind: string) -> []string {
    for o in c.order {
        if o.kind == kind {
            return o.names
        }
    }
    return nil
}

config_destroy :: proc(c: ^Config) {
    for o in c.order {
        delete(o.kind)
        for n in o.names {
            delete(n)
        }
        delete(o.names)
    }
    delete(c.order)
    c.order = nil
}

@(private = "file")
config_set :: proc(c: ^Config, row: conf.Row) -> bool {
    // The one key whose SECTION is a kind rather than a setting group. It is read here rather
    // than in SETTINGS because the section is data: `[edit]` and `[files]` are names a plugin
    // registered, and the table above is a rodata list of pairs.
    if row.key == "spans" {
        config_order(c, row)
        return true
    }
    for s in SETTINGS {
        if s.section == row.section && s.key == row.key {
            s.read(c, row.value)
            return true
        }
    }
    return false
}

// `a, b, c`, in the order written. A name repeated is kept once, at its first position, so a
// line that says a publisher twice ranks it once and reads back the way it was written.
@(private = "file")
config_order :: proc(c: ^Config, row: conf.Row) {
    names := make([dynamic]string, 0, 4)
    rest := row.value
    for part in strings.split_iterator(&rest, ",") {
        name := strings.trim_space(part)
        if name == "" || slice.contains(names[:], name) {
            continue
        }
        append(&names, strings.clone(name))
    }
    for &o in c.order {
        if o.kind == row.section {
            for n in o.names {
                delete(n)
            }
            delete(o.names)
            o.names = names[:]
            return
        }
    }
    append(&c.order, Span_Order{strings.clone(row.section), names[:]})
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

// The two families the editors split into (txt.Split), spelled the way the enum is. The default
// is the zero value, so a value nobody recognises reads as the one the file did not have to say.
@(private = "file")
conf_split :: proc(value: string) -> txt.Split {
    if strings.to_lower(strings.trim_space(value), context.temp_allocator) == "carets" {
        return .Carets
    }
    return .Selections
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

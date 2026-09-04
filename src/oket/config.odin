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
    // The two ordered lists, both keyed by KIND and not by document, because both answers are
    // about the vocabulary a kind is written in:
    //
    //     [<kind>] spans = treesitter, lsp, rainbow   who draws over whom, lowest first (§8)
    //     [<kind>] view  = fold, popup                the view pipeline, in order (§5)
    //
    // A publisher `spans` does not name draws on top of the ones it does (producers.odin). A
    // plugin `view` does not name is not in the pipeline at all — a stage that ran because it
    // was loaded would make load order the layout.
    order:   [dynamic]Kind_Order,
}

// One of those lists, as the file said it. Every string is owned, because the rows the parser
// hands back point into a file body that is temp-allocated.
Kind_Order :: struct {
    kind:  string,
    key:   string,
    names: []string,
}

// The two keys whose SECTION is a kind rather than a setting group. They are read past SETTINGS
// because the section is data: `[edit]` and `[files]` are names a plugin registered, and the
// table below is a rodata list of pairs.
@(private = "file", rodata)
ORDERED := [?]string{"spans", "view"}

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
    conf_forget(a, CONFIG_NAME) // a re-read replaces what the last one found
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

// What the file says this kind's `key` list is, or nothing said. Read per drawn document and per
// built chain, so a line the file grew since is live at the next frame.
config_names :: proc(c: ^Config, kind, key: string) -> []string {
    for o in c.order {
        if o.kind == kind && o.key == key {
            return o.names
        }
    }
    return nil
}

config_destroy :: proc(c: ^Config) {
    for o in c.order {
        delete(o.kind)
        delete(o.key)
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
    if slice.contains(ORDERED[:], row.key) {
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
        if o.kind == row.section && o.key == row.key {
            for n in o.names {
                delete(n)
            }
            delete(o.names)
            o.names = names[:]
            return
        }
    }
    append(&c.order, Kind_Order{strings.clone(row.section), strings.clone(row.key), names[:]})
}

// --- what a plugin asked for (§7) ---
//
// HELD, NOT APPLIED, the rule request_bind already follows one file over: nothing here touches
// the live Config. A request becomes a ROW, once, and from then on the file decides — which is
// what makes installing a view stage `cp` and nothing else, and uninstalling one an edit that
// sticks.

Config_Request :: struct {
    owner:   string, // owned; the plugin's name, and the section marker it is written under
    section: string, // owned; a kind, or a setting group
    key:     string, // owned
    value:   string, // owned
    dead:    bool, // its plugin unloaded; the row it already wrote is the file's now
}

// Answers whether a request was held, so the caller's ledger only records ones that were.
config_request :: proc(a: ^App, owner, section, key, value: string) -> bool {
    if owner == "" || section == "" || key == "" || value == "" {
        return false
    }
    append(&a.creqs, Config_Request{strings.clone(owner), strings.clone(section),
                                    strings.clone(key), strings.clone(value), false})
    return true
}

config_requests_destroy :: proc(a: ^App) {
    for r in a.creqs {
        delete(r.owner)
        delete(r.section)
        delete(r.key)
        delete(r.value)
    }
    delete(a.creqs)
    a.creqs = nil
}

// The file first, then what was requested, then a re-read only if that changed anything. One
// path in, so a requested row and a typed row are indistinguishable once they are in.
config_sync :: proc(a: ^App) {
    config_load(a)
    // No home is a test holding an App of its own. Writing would land beside the test binary,
    // which races the parallel runner and is not this App's file to write.
    if a.home == "" || len(a.creqs) == 0 {
        return
    }
    path, _ := filepath.join({a.home, CONFIG_NAME}, context.temp_allocator)
    if config_writeback(a, path) {
        config_load(a)
    }
}

@(private = "file")
config_marker :: proc(owner: string) -> string {
    return fmt.tprintf("# --- %s ---", owner)
}

// Appends a marked block per owner that has none yet, and answers whether the file changed.
//
// ASKED ONCE. The marker being there is the record, so a name a user then deletes from a `view`
// line stays deleted — the same reason binds.conf keys its writeback on an owner header and not
// on the rows.
@(private = "file")
config_writeback :: proc(a: ^App, path: string) -> bool {
    text := ""
    if raw, err := os.read_entire_file(path, context.temp_allocator); err == nil {
        text = string(raw)
    }
    rows, _ := conf.parse(text)
    lines := strings.split_lines(text, context.temp_allocator)

    add := strings.builder_make(context.temp_allocator)
    done := make(map[string]bool, 0, context.temp_allocator)
    wrote := false
    for r in a.creqs {
        if r.dead {
            continue
        }
        if done[r.owner] || strings.contains(text, config_marker(r.owner)) {
            done[r.owner] = true
            continue
        }
        done[r.owner], wrote = true, true
        fmt.sbprintf(&add, "\n%s\n", config_marker(r.owner))
        config_owner_rows(a, rows, lines, &add, r.owner)
    }
    if !wrote {
        return false
    }
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, strings.join(lines, "\n", context.temp_allocator))
    if text != "" && !strings.has_suffix(text, "\n") {
        strings.write_byte(&b, '\n')
    }
    strings.write_string(&b, strings.to_string(add))
    return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}

// One owner's live requests, under its marker. A row the file already has is the file's answer,
// except for the ordered lists, where the answer is a SET and not a value: a second stage has to
// be able to join one. It is joined in place, so the order the user wrote is kept.
@(private = "file")
config_owner_rows :: proc(a: ^App, rows: []conf.Row, lines: []string, add: ^strings.Builder,
                          owner: string) {
    section := ""
    for q in a.creqs {
        if q.dead || q.owner != owner {
            continue
        }
        if at, held := config_row_at(rows, q.section, q.key); held {
            if slice.contains(ORDERED[:], q.key) {
                lines[at - 1] = config_join(lines[at - 1], q.value)
            }
            continue
        }
        if section != q.section {
            fmt.sbprintf(add, "[%s]\n", q.section)
            section = q.section
        }
        fmt.sbprintf(add, "%s = %s\n", q.key, q.value)
    }
}

// Which LINE holds this section's key, if the file holds it at all.
@(private = "file")
config_row_at :: proc(rows: []conf.Row, section, key: string) -> (int, bool) {
    for r in rows {
        if r.section == section && r.key == key {
            return r.line, true
        }
    }
    return 0, false
}

// `key = a, b` plus `c`; the row unchanged when it already names it.
@(private = "file")
config_join :: proc(line, name: string) -> string {
    _, _, value := strings.partition(line, "=")
    rest := value
    for part in strings.split_iterator(&rest, ",") {
        if strings.trim_space(part) == name {
            return line
        }
    }
    return strings.concatenate({strings.trim_right_space(line), ", ", name},
                               context.temp_allocator)
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

// A line of config.conf or binds.conf the parse could not use. Two readers, because they
// answer at different times: the bar says the last one NOW, and the home page lists them all at
// the next start, which is the moment a typo actually costs you a chord (§13).
Gripe :: struct {
    file: string, // owned
    line: int,
    why:  string, // owned
}

// One bad row is reported and skipped, never fatal — for both files the kernel reads.
conf_complain :: proc(a: ^App, file: string, line: int, why: string) {
    append(&a.gripes, Gripe{strings.clone(file), line, strings.clone(why)})
    message_set(a, fmt.tprintf("%s:%d: %s", file, line, why))
}

// One file's gripes, dropped. Called at the top of every parse, because binds.conf is read
// twice in a sync and a list that only grows would report one typo as two.
conf_forget :: proc(a: ^App, file: string) {
    for i := len(a.gripes) - 1; i >= 0; i -= 1 {
        if a.gripes[i].file == file {
            delete(a.gripes[i].file)
            delete(a.gripes[i].why)
            ordered_remove(&a.gripes, i)
        }
    }
}

gripes_destroy :: proc(a: ^App) {
    for g in a.gripes {
        delete(g.file)
        delete(g.why)
    }
    delete(a.gripes)
    a.gripes = nil
}

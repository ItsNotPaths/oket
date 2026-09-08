package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../conf"
import "../input"
import "../txt"

// `config.conf` (§4): the settings the kernel keeps, in the flat `key = value` format
// `binds.conf` already uses and through the same parser. Both files are ones the kernel WRITES,
// which is what ruled out TOML for either.
//
// A row that names no setting is REPORTED, and the rest of the file still lands. A typo that
// silently does nothing is the failure the input design exists to prevent (§8), and it is the
// rule binds.conf follows for a bad row.
//
// Eleven settings today, which is §4's tripwire: if this grows nesting, flat keys start encoding
// structure in their names — `lang.odin.tab_width` — and that is a worse TOML. Revisit there.

CONFIG_NAME :: "config.conf" // in the config directory, next to binds.conf (path.odin)

Config :: struct {
    restore: bool, // [session] restore = on — the ring, across restarts (session.odin)
    gap:     int, // [strip] gap = 4 — pixels between two panels (PANELS.md §5, §7)
    behind:  int, // [strip] behind = 12 — percent the surface behind the panels is darkened
    tau:     int, // [strip] tau = 90 — milliseconds the strip's motion decays by 1/e (§7)
    select:  int, // [cursor] select = 90 — percent of the swap a selection carries (§3)
    wheel:   int, // [mouse] wheel = 3 — lines one notch scrolls
    double_ms: int, // [mouse] double = 300 — the double-click window (PLAN.md §14)
    font_px: int, // [font] size = 18 — the face size to bake at; 0 is the display's own
    split:   txt.Split, // [cursor] split = selections — what cursor.split_lines leaves per line
    switcher: Switcher_Show, // [switcher] show = titles — what the alt column carries
    // [theme] name = gruvbox — which themes/<name>.toml colours everything (theme.odin). Owned
    // when set; "" IS the default name, so the field never holds a literal a destroy would free.
    theme:   string,
    // The two ordered lists, both keyed by KIND and not by document, because both answers are
    // about the vocabulary a kind is written in:
    //
    //     [<kind>] spans = treesitter, lsp, rainbow   who draws over whom, lowest first (§8)
    //     [<kind>] view  = fold, example              the view pipeline, in order (§5)
    //
    // A publisher `spans` does not name draws on top of the ones it does (producers.odin). A
    // plugin `view` does not name is not in the pipeline at all — a stage that ran because it
    // was loaded would make load order the layout.
    //
    // `[menu]` keeps its lists here too, keyed by the section rather than by the key, because
    // every key in that section is one (menubar.odin).
    order:   [dynamic]Kind_Order,
    // `[alias] name = line` — a new verb whose body is a chain (chain.odin expands it at
    // parse). File rows override ALIASES_DEFAULT; builtins and plugin commands win a clash.
    aliases: [dynamic]Alias,
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

ALIAS_SECTION :: "alias"

// A named line: `:name` runs it, expanded at parse so `:name && :ls` composes like anything
// typed. The naming rung between a bind row and a plugin — the body is still chain and bash.
Alias :: struct {
    name: string,
    line: string,
    doc:  string, // the generated file's comment; "" on a file-defined row
}

// The vocabulary oket ships. In code, not in the file, for the reason the settings block is
// commented: a release changing one must reach people who already have the file.
@(rodata)
ALIASES_DEFAULT := [?]Alias {
    {"panel.equalize",
     `:get panels | awk 'END { for (i = 1; i <= NR; i++) print ":width " int(100 / NR) " @" i }' | :do`,
     "every panel to an equal share of the strip"},
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

// A selection that stops just short of the full swap: the syntax under it still reads, and the
// caret on top of it is the one thing still drawn at 100.
SELECT_DEFAULT :: 90

// One wheel notch, and the window a second click still counts as a double one (§14: a timeout
// is invisible state, so the file must be able to say what it is). The window's one value is
// the mouse machine's, which also serves its callers that have no config to read.
WHEEL_DEFAULT :: 3
DOUBLE_DEFAULT :: input.DOUBLE_CLICK_MS

config_default :: proc() -> Config {
    return {gap = GAP_DEFAULT, tau = TAU_DEFAULT, behind = BEHIND_DEFAULT,
            select = SELECT_DEFAULT, wheel = WHEEL_DEFAULT, double_ms = DOUBLE_DEFAULT}
}

// A setting is where it is written, what it MEANS, its default as you would type it, and what
// reading it does — so adding one is a field above and a row here, and nowhere else.
//
// The file the user edits is written FROM this table, so a setting with no `doc` is one nobody
// can find. `def` is a string because that is what the file holds; the drift gate parses every
// one back and checks it against config_default.
@(private = "file")
Setting :: struct {
    section: string,
    key:     string,
    def:     string,
    doc:     string,
    read:    proc(c: ^Config, value: string),
}

// The settings whose value is a LIST. config_set routes these to config_order before SETTINGS
// is ever consulted, so they need their own table to be written down — and being unwritable is
// exactly how `[menu] palette` came to be a setting nobody could find.
//
// No reader: the ordered path stores a list by name and the site that wants one asks
// config_names for it, so there is no Config field to parse into.
@(private = "file")
List_Setting :: struct {
    section: string,
    key:     string,
    def:     string,
    doc:     string,
}

@(private = "file", rodata)
LISTS := [?]List_Setting {
    {"menu", "bar", "file, edit, view, panel", "which menus the bar carries, in order"},
    {"menu", "palette", "invert",
     "the bar's colours: dark, light, or invert for the opposite of the theme"},
    {"menu", "show", "hidden",
     "constant keeps the bar on a row of its own; hidden draws it over what is there"},
}

// The forms whose KEY or SECTION is a name the user picks, so no row can stand for them. Written
// into the block as prose, because a shape is the only thing there is to say.
@(private = "file", rodata)
SHAPES := [?]string {
    "[menu] <name> = <namespace>...   what one menu holds; `bar` above says which menus exist",
    "[<kind>] spans = <plugin>...     who draws over whom in that kind, lowest first",
    "[<kind>] view  = <plugin>...     the view pipeline for that kind, in order",
    "[alias] <name> = <line>          a new verb: `:name` runs the line; builtins keep a clashing name",
}

@(private = "file", rodata)
SETTINGS := [?]Setting {
    {"session", "restore", "off", "reopen what was open at the last clean exit",
     proc(c: ^Config, value: string) {c.restore = conf_on(value)}},
    {"strip", "gap", "4", "pixels between two panels; zero puts two documents against each other",
     proc(c: ^Config, value: string) {c.gap = conf_int(value, GAP_DEFAULT)}},
    {"strip", "tau", "90",
     "milliseconds the strip's motion decays by 1/e; 0 lands everything at once",
     proc(c: ^Config, value: string) {c.tau = conf_int(value, TAU_DEFAULT)}},
    {"strip", "behind", "12", "percent the surface behind the panels is darkened",
     proc(c: ^Config, value: string) {c.behind = conf_int(value, BEHIND_DEFAULT)}},
    {"cursor", "select", "90", "percent of the swap a selection carries",
     proc(c: ^Config, value: string) {c.select = conf_int(value, SELECT_DEFAULT)}},
    {"cursor", "split", "selections",
     "what cursor.split_lines leaves per line: selections or carets",
     proc(c: ^Config, value: string) {c.split = conf_split(value)}},
    // 0 is what an absent row means and what `font.reset` goes back to; the range guard is
    // face_px_ok's, at the read site.
    {"font", "size", "0", "the face size to bake at; 0 is whatever the display asked for",
     proc(c: ^Config, value: string) {c.font_px = conf_int(value, 0)}},
    {"mouse", "wheel", "3", "lines one wheel notch scrolls",
     proc(c: ^Config, value: string) {c.wheel = conf_int(value, WHEEL_DEFAULT)}},
    {"mouse", "double", "300",
     "milliseconds within which a second click is a double one",
     proc(c: ^Config, value: string) {c.double_ms = conf_int(value, DOUBLE_DEFAULT)}},
    {"switcher", "show", "titles",
     "what the column under a held alt carries: titles or numbers",
     proc(c: ^Config, value: string) {c.switcher = conf_switcher(value)}},
    {"theme", "name", THEME_DEFAULT,
     "which themes/<name>.toml colours everything; the default is baked in",
     proc(c: ^Config, value: string) {
         delete(c.theme)
         c.theme = {}
         if v := strings.trim_space(value); v != THEME_DEFAULT {
             c.theme = strings.clone(v)
         }
     }},
}

config_load :: proc(a: ^App) {
    config_destroy(&a.config)
    a.config = config_default()
    if a.home.config == "" {
        return
    }
    path, _ := filepath.join({a.home.config, CONFIG_NAME}, context.temp_allocator)
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
            conf_complain(a, CONFIG_NAME, row.line, config_refusal(row.section, row.key))
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
    delete(c.theme)
    c.theme = {}
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
    for al in c.aliases { // doc is never cloned, so it is not freed
        delete(al.name)
        delete(al.line)
    }
    delete(c.aliases)
    c.aliases = nil
}

// A refused row shadows a builtin: `:close` meaning something else is invisible state, so the
// name stays the kernel's and the row is complained about (config_load, builtin_set). Plugin
// commands cannot be checked here — no App — so they win at EXPANSION instead (chain.odin).
@(private = "file")
config_alias :: proc(c: ^Config, row: conf.Row) -> bool {
    if _, shadows := builtin_named(row.key); shadows {
        return false
    }
    for &al in c.aliases {
        if al.name == row.key {
            delete(al.line)
            al.line = strings.clone(row.value)
            return true
        }
    }
    append(&c.aliases, Alias{strings.clone(row.key), strings.clone(row.value), ""})
    return true
}

// The line an alias name stands for, "" for no alias. The file's row wins over the shipped
// default, which is how a user rewrites `panel.equalize` without touching code.
config_alias_line :: proc(c: ^Config, name: string) -> string {
    for al in c.aliases {
        if al.name == name {
            return al.line
        }
    }
    for al in ALIASES_DEFAULT {
        if al.name == name {
            return al.line
        }
    }
    return ""
}

// `:set` runs one row through the same door the file's rows come in (builtins.odin), so a
// typed setting and a read one are indistinguishable once they are in. The change is this
// session's: nothing here writes config.conf.
config_set_line :: proc(c: ^Config, section, key, value: string) -> bool {
    return config_set(c, conf.Row{section = section, key = key, value = value})
}

// Why config_set said no, worded once for both doors (config_load, builtin_set): the only row
// an `[alias]` section refuses is one shadowing a builtin. Temp-allocated.
config_refusal :: proc(section, key: string) -> string {
    if section == ALIAS_SECTION {
        return fmt.tprintf("[alias] %s shadows a builtin", key)
    }
    return fmt.tprintf("[%s] %s is not a setting", section, key)
}

@(private = "file")
config_set :: proc(c: ^Config, row: conf.Row) -> bool {
    // Before the ORDERED check: an alias may be CALLED `view` or `spans`, and its value is a
    // line, never a comma list.
    if row.section == ALIAS_SECTION {
        return config_alias(c, row)
    }
    // `[menu]` is lists all the way down (MENU.md §2): every key in it names a menu, so the
    // SECTION is what says the value is a list, where the two above are said by the key.
    if row.section == MENU_SECTION || slice.contains(ORDERED[:], row.key) {
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
    defer theme_sync(a) // any of the reads below may have moved [theme] name
    config_load(a)
    // No home is a test holding an App of its own. Writing would land beside the test binary,
    // which races the parallel runner and is not this App's file to write.
    //
    // A directory that cannot be written is the OTHER refusal (INSTALL.md §2): an Installed oket
    // has none until `:oket install` makes them, and a Portable one unpacked somewhere root owns
    // never will. The file still READS in both cases; what stops is writing to it.
    if !home_writable(a.home.config) {
        return
    }
    path, _ := filepath.join({a.home.config, CONFIG_NAME}, context.temp_allocator)
    // The kernel's own block first, so a start with no plugins at all still leaves a file that
    // says what there is to set. Both writes are marker-keyed and asked once.
    wrote := config_defaults_write(a, path)
    if config_writeback(a, path) || wrote {
        config_load(a)
    }
}

// Every setting, commented out, under its section. COMMENTED because the defaults live in code
// (§8's rule for binds.conf, and the same reason): a file that DEFINED them would mean a release
// changing one never reaches anyone who already has the file. This block is documentation the
// user can uncomment, and it is generated from SETTINGS so it cannot drift from what is read.
// Not file-private: `:oket install` lays the file down in the one place it is ever created, and
// it has to be the same block the kernel would have written (install.odin).
config_defaults_write :: proc(a: ^App, path: string) -> bool {
    text := ""
    if raw, err := os.read_entire_file(path, context.temp_allocator); err == nil {
        text = string(raw)
    }
    if strings.contains(text, config_marker(DEFAULTS_OWNER)) {
        return false // asked once; a user who deleted a line meant to delete it
    }
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b, "%s\n", config_marker(DEFAULTS_OWNER))
    strings.write_string(&b, "# Every setting oket has, with its default. Uncomment to change\n")
    strings.write_string(&b, "# one; a commented row is the default, which lives in the code.\n")
    section := ""
    for s in SETTINGS {
        if s.section != section {
            section = s.section
            fmt.sbprintf(&b, "\n[%s]\n", section)
        }
        fmt.sbprintf(&b, "# %s\n# %s = %s\n", s.doc, s.key, s.def)
    }
    for l in LISTS {
        if l.section != section {
            section = l.section
            fmt.sbprintf(&b, "\n[%s]\n", section)
        }
        fmt.sbprintf(&b, "# %s\n# %s = %s\n", l.doc, l.key, l.def)
    }
    strings.write_string(&b, "\n[alias]\n")
    for al in ALIASES_DEFAULT {
        fmt.sbprintf(&b, "# %s\n# %s = %s\n", al.doc, al.name, al.line)
    }
    strings.write_string(&b, "\n# And four forms whose name is yours to pick, so no row above\n")
    strings.write_string(&b, "# can stand for them:\n")
    for shape in SHAPES {
        fmt.sbprintf(&b, "#   %s\n", shape)
    }
    body := strings.to_string(b)
    if text != "" && !strings.has_suffix(text, "\n") {
        body = fmt.tprintf("\n%s", body)
    }
    return os.write_entire_file(path, transmute([]u8)fmt.tprintf("%s%s", text, body)) == nil
}

// Not a plugin name, and it cannot collide with one: a plugin's marker is its own name and no
// plugin is called this.
DEFAULTS_OWNER :: "oket"

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

// What the alt column carries (Switcher_Show), spelled the way the enum is.
@(private = "file")
conf_switcher :: proc(value: string) -> Switcher_Show {
    if strings.to_lower(strings.trim_space(value), context.temp_allocator) == "numbers" {
        return .Numbers
    }
    return .Titles
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

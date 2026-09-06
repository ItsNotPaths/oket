package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../desc"
import "../store"
import "../txt"

// The kernel's curated core set (§12). Everything past it arrives with plugins, and the sigil
// promised a builtin, so an unknown name stops the chain and says so rather than falling
// through to the shell — a `:` that silently ran something else would be the worst of both.
//
// A builtin is one ROW: its name, its definition, and what running it does. The same shape a
// setting has (config.odin) and a verb has (COMMANDS), and for the same reason — the menubar
// reads the definition (MENU.md §3) and a bad parse reports the usage, so one row is what keeps
// the two from drifting apart.

Builtin :: struct {
    name:  string,
    also:  string, // a second spelling, empty for most
    // The namespace it sits in, which is the menu it is listed under (MENU.md §2). Written down
    // rather than read off the name, because `:open` has no dot to read one from.
    menu:  string,
    usage: string,
    doc:   string,
    // `args` is the line past the name. `step` is the whole step, for the one builtin that
    // reads what was piped into it.
    run:   proc(a: ^App, args: string, step: CL_Step) -> bool,
}

@(rodata)
BUILTINS := [?]Builtin {
    {"open", "", "file", USAGE_OPEN,
     "open a file or a directory; one already in the ring is moved to, not opened twice",
     builtin_open},
    {"ring", "", "ring", ":ring [<kind>]",
     "go to that kind's lane; with no kind, list the lanes",
     builtin_ring},
    {"ls", "", "ring", ":ls",
     "print every live slot of every lane into the system session",
     builtin_ls},
    {"close", "", "ring", ":close",
     "close the focused slot; its number is never reused while others live",
     builtin_close},
    {"find", "", "edit", USAGE_FIND,
     "select every match at once, so typing replaces them all; f3 steps through them one at a time",
     builtin_find},
    {"sel", "", "edit", ":sel",
     "put the selection, or the line point is on, on the next step's stdin",
     builtin_sel},
    {"put", "", "edit", ":put",
     "replace the selection with what was piped into it",
     builtin_put},
    {"recover", "", "file", USAGE_RECOVER,
     "take back the work a crash left on that file, or throw it away",
     builtin_recover},
    {"width", "", "panel", USAGE_WIDTH,
     "size the panel; a list of percents is a cycle, and one is a set",
     builtin_width},
    {"np", "new-panel", "panel", ":np",
     "a panel to the right of this one, standing on nothing",
     builtin_np},
    {"home", "", "file", ":home [enter]",
     "open the home page; `enter` takes the offer the row point is on",
     builtin_home},
    {"plug", "", "plug", USAGE_PLUG,
     "load, unload or reload a plugin; with no verb, list what is in",
     builtin_plug},
    {"pluginify", "", "plug", USAGE_PLUGINIFY,
     "build a plugin directory and load what came out",
     builtin_pluginify},
    {"q", "", "file", ":q",
     "close the window",
     builtin_quit},
}

// The row a name reaches, either spelling. Walked and not hashed: the set is small and this
// runs once per typed line, never once per keystroke.
builtin_named :: proc(name: string) -> (Builtin, bool) {
    for b in BUILTINS {
        if b.name == name || b.also != "" && b.also == name {
            return b, true
        }
    }
    return {}, false
}

cl_builtin :: proc(a: ^App, step: CL_Step) -> bool {
    name := first_field(step.text)
    args := strings.trim_space(step.text[len(name):])
    if b, is_builtin := builtin_named(name); is_builtin {
        return b.run(a, args, step)
    }
    // Past the core set the registry answers, so a plugin's command is typed exactly the way a
    // builtin is and nothing downstream can tell which it was (§12).
    if slot, registered := plug_cmd_named(a, name); registered {
        return plug_command(a, slot, args)
    }
    message_set(a, fmt.tprintf("%s: not a builtin (drop the : to run it in the shell)", name))
    return false
}

// ring.close as a command line. alt+q already does exactly this, and a plugin that opened a
// document will have no other way to end it (stage 7).
@(private = "file")
builtin_close :: proc(a: ^App, _: string, _: CL_Step) -> bool {
    if ring_focused(a) == nil {
        message_set(a, ":close: nothing is focused")
        return false
    }
    ring_close(a, ring_slot(a))
    return true
}

// `panel.open` as a command line, which is what the picker's second `tab+enter` runs: a panel
// to the right of the one the keys are aimed at, and the aim goes with it.
@(private = "file")
builtin_np :: proc(a: ^App, _: string, _: CL_Step) -> bool {
    panel_open(a)
    return true
}

// `:home enter` is the page's own row acting on itself; a bare `:home` asks for the page. Both
// are lines you could type, which is what keeps the page a document.
@(private = "file")
builtin_home :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    if _, verb := first_arg(args); verb == "enter" {
        return home_enter(a)
    }
    ring_add(a, home_open(a))
    return true
}

@(private = "file")
builtin_quit :: proc(a: ^App, _: string, _: CL_Step) -> bool {
    a.quit = true
    return true
}

// `:open <path> [#slot] [@panel]`. The target is an ARGUMENT, which is what makes the routing
// typed, visible and editable before it commits (§5): `stage :open <path>` puts the line in the
// command line and you aim it there. No routing hook, no display-buffer-alist.
//
// The panel is reached BEFORE the document is placed, so the open is an ordinary one from
// there: what `@N` does is aim the keys, and the ring then answers the way it does for any
// other panel. Which is also why the open takes focus with it — you always see where it went.
@(private = "file")
builtin_open :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    raw, path := first_arg(args)
    rest := strings.trim_space(args[len(raw):])
    if path == "" {
        message_set(a, USAGE_OPEN)
        return false
    }
    target, bad, aimed := target_parse(rest)
    if !aimed {
        message_set(a, fmt.tprintf(":open: %s is not a slot or a panel (%s)", bad, USAGE_OPEN))
        return false
    }
    id, ok := open_path(a, path)
    if !ok {
        return false
    }
    panel_focus(a, target_reach(a, target, id))
    if target.slot == 0 {
        ring_add(a, id)
    } else if !ring_put(a, id, target.slot) {
        // The document was already open, so `#N` names a slot it is not in. Reported rather
        // than obeyed: a slot is where a document went the first time, and moving it silently
        // would leave the number you had memorised pointing at a gap.
        message_set(a, fmt.tprintf(":open: %s is already #%d", path, ring_slot(a)))
    }
    return true
}

USAGE_OPEN :: ":open <path> [#slot] [@panel]"

// `:width <percent>... [@panel]`. The sizing model is the ROW and not the kernel (PANELS.md §5):
// a list is a cycle, so `:width 100 50` is a toggle, `:width 100 50 33` is a three-way, and
// `:width 50` is a set. `alt+w` is a line bind over this and nothing else.
//
// A bare number is a percent here and never a `#slot`, because a panel has no slot to name.
@(private = "file")
builtin_width :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    pcts := make([dynamic]int, 0, 4, context.temp_allocator)
    target: Target
    rest := strings.trim_space(args)
    for rest != "" {
        field := first_field(rest)
        rest = strings.trim_space(rest[len(field):])
        if field[0] == '@' {
            aimed: bool
            target, _, aimed = target_parse(field) // the last `@` wins, target_parse's own rule
            if !aimed {
                message_set(a, fmt.tprintf(":width: %s is not a panel (%s)", field, USAGE_WIDTH))
                return false
            }
            continue
        }
        pct, num := width_pct(field)
        if !num {
            message_set(a, fmt.tprintf(":width: %s is not a percent (%s)", field, USAGE_WIDTH))
            return false
        }
        append(&pcts, pct)
    }
    if len(pcts) == 0 {
        message_set(a, USAGE_WIDTH)
        return false
    }
    i, live := target_panel(a, target)
    if !live {
        message_set(a, ":width: the strip has no such panel")
        return false
    }
    panel_width(a, i, pcts[:])
    return true
}

USAGE_WIDTH :: ":width <percent>... [@panel]"

// A percent, or one of the four words for the ones worth a name. Out of range is REPORTED and
// not clamped: a row that says 200 meant something, and sizing it to 100 in silence hides it.
@(private = "file")
width_pct :: proc(field: string) -> (int, bool) {
    switch field {
    case "full":
        return 100, true
    case "half":
        return 50, true
    case "third":
        return 33, true
    case "quarter":
        return 25, true
    }
    n, num := strconv.parse_int(field, 10)
    return n, num && n >= WIDTH_MIN && n <= WIDTH_FULL
}

// A directory goes to whoever registered the `files` kind and to the kernel's own listing when
// nobody did; a file goes to whoever registered `edit`, which is the editor plugin (§7). The
// kernel reads no file into a document of its own — that would be a privileged path — and the
// path is all it hands over.
open_path :: proc(a: ^App, path: string) -> (store.Id, bool) {
    info, err := os.stat(path, context.temp_allocator)
    if err != nil {
        message_set(a, fmt.tprintf(":open: cannot read %s: %v", path, err))
        return {}, false
    }
    // ONE PATH, ONE DOCUMENT (the why is on ring_file), and `./x` and `x` are the same file
    // (path_abs) whatever the line said.
    if id, open := ring_file(a, path_abs(path)); open {
        return id, true
    }
    if info.type == .Directory {
        return files_open(a, path)
    }
    kind, registered := kind_named(a, KIND_EDIT)
    if !registered {
        message_set(a, fmt.tprintf(":open: nothing registers the %s kind, so nothing opens a file (:plug load %s)",
                                   KIND_EDIT, KIND_EDIT))
        return {}, false
    }
    return plug_open(a, kind, path)
}

// `:ring <kind>`: go to that kind's lane (§5). What a `[global] alt+e = exec :ring edit` row
// runs, and the reason it is a row rather than a case in the dispatch — the kind is named in
// the config and never in kernel source.
@(private = "file")
builtin_ring :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    _, name := first_arg(args)
    if name == "" {
        for l, i in a.ring.lanes {
            sys_println(a, fmt.tprintf("%s%s", i == ring_lane(a) ? "> " : "  ", kind_name(a, l.kind)))
        }
        ring_show_system(a)
        return true
    }
    lane, found := ring_lane_named(a, name)
    if !found {
        message_set(a, fmt.tprintf(":ring: nothing has registered a kind called %s", name))
        return false
    }
    // A lane with nothing in it still opens: slot 1 of it, which is what makes `:ring edit`
    // useful before the first file is open.
    if !ring_lane_enter(a, lane) {
        message_set(a, fmt.tprintf(":ring: %s opened nothing", name))
        return false
    }
    return true
}

// The ring, printed into N#, which surfaces to show it.
@(private = "file")
builtin_ls :: proc(a: ^App, _: string, _: CL_Step) -> bool {
    n := 0
    for l, lane in a.ring.lanes {
        for s, i in l.slots {
            if !s.live {
                continue // a gap keeps its number; it just has nothing in it
            }
            here := lane == ring_lane(a) && i + 1 == ring_slot(a)
            sys_println(a, fmt.tprintf("%s%s %d %s", here ? "> " : "  ", kind_name(a, l.kind),
                                       i + 1, doc_title(a, s.doc)))
            n += 1
        }
    }
    if n == 0 {
        sys_println(a, "the ring is empty")
    }
    ring_show_system(a)
    return true
}

// --- the two boundaries a shell cannot see ---

// `:sel` puts the selection on the next step's stdin. With nothing selected it takes the line
// under point and SELECTS it, so what a following `:put` replaces is what you were shown —
// same rule as `edit.copy`, which takes the selection or the line.
@(private = "file")
builtin_sel :: proc(a: ^App, _: string, _: CL_Step) -> bool {
    s := ring_focused(a)
    if s == nil {
        message_set(a, ":sel: nothing is focused")
        return false
    }
    doc := store.store_doc(&a.docs, s.doc)
    if doc == nil {
        return false
    }
    c := doc.cursors[doc.primary]
    if !txt.cursor_has_selection(c) {
        txt.doc_select_line(doc, c.head.line)
        c = doc.cursors[doc.primary]
    }
    lo, hi := txt.cursor_range(c)
    text := txt.doc_text(doc, lo, hi, context.temp_allocator)
    chain_feed(a, text)
    s.view.point = doc.cursors[doc.primary]
    return true
}

// `:put` takes what was piped into it and replaces the selection with it, at point. Emacs's
// shell-command-on-region, as a chain step: `:sel | sort -u | :put`.
@(private = "file")
builtin_put :: proc(a: ^App, _: string, step: CL_Step) -> bool {
    if !step.piped || !a.chain.fed {
        message_set(a, ":put: nothing was piped into it")
        return false
    }
    s := ring_focused(a)
    if s == nil {
        message_set(a, ":put: nothing is focused")
        return false
    }
    d := store.store_descriptor(&a.docs, s.doc)
    defer desc.release(d)
    if d == nil || !d.editable {
        message_set(a, ":put: this document does not take typing")
        return false
    }
    doc := store.store_doc(&a.docs, s.doc)
    txt.doc_insert_text(doc, a.chain.feed) // one edit per cursor, replacing its range
    s.view.point = doc.cursors[doc.primary]
    return true
}

// `:recover <path>` takes the work a crash left on that file back, and `:recover drop <path>`
// throws it away. The argument is the DOCUMENT, not the journal file: a journal is named after
// the document it shadows (journal.odin), so the visible half of a home-page row is the whole
// of what the row acts on and hover underlines what `enter` would take (§14).
@(private = "file")
builtin_recover :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    raw, first := first_arg(args)
    drop := first == "drop"
    path := first
    if drop {
        _, path = first_arg(strings.trim_space(args[len(raw):]))
    }
    if path == "" {
        message_set(a, USAGE_RECOVER)
        return false
    }
    journal := journal_path(a, path)
    if journal == "" || !os.exists(journal) {
        message_set(a, fmt.tprintf(":recover: nothing was journaled for %s", path))
        return false
    }
    ok := drop ? recover_drop(a, journal) : recover_apply(a, journal)
    home_refresh(a) // the row that offered it is stale either way
    return ok
}

USAGE_RECOVER :: ":recover [drop] <path>"

// --- the plugin seam (§7) ---

// `:plug [load|unload|reload] <name>`, and bare `:plug` lists what is in. A plugin is one `.so`
// under `plugins/` in the data directory; the name is its file's stem, and it is also the section
// header its bind requests land under in binds.conf.
@(private = "file")
builtin_plug :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    raw, verb := first_arg(args)
    _, name := first_arg(strings.trim_space(args[len(raw):]))
    if verb != "" && name == "" {
        message_set(a, USAGE_PLUG)
        return false
    }
    switch verb {
    case "":
        return plug_list(a)
    case "load":
        ok := plug_load(a, plug_path(a, name))
        home_refresh(a) // the page that named it as quarantined offered this, and is stale now
        return ok
    case "unload":
        if i := plug_find(a, name); i >= 0 {
            return plug_unload(a, i)
        }
        message_set(a, fmt.tprintf(":plug: %s is not loaded", name))
        return false
    case "reload":
        return plug_reload(a, name)
    }
    message_set(a, USAGE_PLUG)
    return false
}

USAGE_PLUG :: ":plug [load|unload|reload] <name>"

@(private = "file")
plug_list :: proc(a: ^App) -> bool {
    n := 0
    for p in a.plugs {
        if !p.live {
            continue
        }
        kinds, cmds := 0, 0
        for r in p.ledger {
            switch r.what {
            case .Kind:
                kinds += 1
            case .Command:
                cmds += 1
            case .Bind, .Watch, .View, .Config:
            }
        }
        stage := p.viewer != nil ? ", a view stage" : ""
        sys_println(a, fmt.tprintf("%s  %d kind(s), %d command(s)%s  %s", p.name, kinds, cmds,
                                   stage, p.path))
        n += 1
    }
    if n == 0 {
        sys_println(a, "no plugins are loaded")
    }
    ring_show_system(a)
    return true
}

// `:pluginify <dir>`: build a plugin directory and load what came out. It hands the chain a
// command line rather than running a compiler itself, so an error lands in N# where `enter`
// over a `file:line` opens the file. The recipe is plugins/stage.sh and nothing else:
// release.sh and the gate tests run the same script, so this build is the shipped build.
@(private = "file")
builtin_pluginify :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    raw, dir := first_arg(args)
    flags := strings.trim_space(args[len(raw):])
    if dir == "" {
        message_set(a, USAGE_PLUGINIFY)
        return false
    }
    if flags != "" && flags != "--asan" {
        message_set(a, fmt.tprintf(":pluginify: %s is not a flag it knows", flags))
        return false
    }
    if !os.is_dir(dir) {
        message_set(a, fmt.tprintf(":pluginify: %s is not a directory", dir))
        return false
    }
    abs, _ := filepath.abs(dir, context.temp_allocator)
    if abs == "" {
        abs = dir
    }
    script, _ := filepath.join({a.home.data, PLUGINIFY_SCRIPT}, context.temp_allocator)
    if !os.exists(script) {
        message_set(a, fmt.tprintf(":pluginify: no build script at %s", script))
        return false
    }
    out, _ := filepath.join({a.home.data, PLUGIN_DIR}, context.temp_allocator)
    name := filepath.base(abs)
    // Reloaded rather than loaded when it is already in: rebuilding the plugin you are running
    // is the loop this verb exists for, and `:plug load` refuses a name it already has.
    verb := plug_find(a, name) >= 0 ? "reload" : "load"
    cl_exec(a, fmt.tprintf("%s %s %s%s && :plug %s %s",
                           sh_quote(script, context.temp_allocator),
                           sh_quote(abs, context.temp_allocator),
                           sh_quote(out, context.temp_allocator),
                           flags == "" ? "" : " --asan", verb, name))
    return true
}

USAGE_PLUGINIFY :: ":pluginify <dir> [--asan]"
PLUGINIFY_SCRIPT :: "stage.sh"

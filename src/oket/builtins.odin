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

cl_builtin :: proc(a: ^App, step: CL_Step) -> bool {
    name := first_field(step.text)
    args := strings.trim_space(step.text[len(name):])
    switch name {
    case "open":
        return builtin_open(a, args)
    case "ring":
        return builtin_ring(a, args)
    case "ls":
        return builtin_ls(a)
    case "sel":
        return builtin_sel(a)
    case "put":
        return builtin_put(a, step)
    case "close":
        // ring.close as a command line. alt+q already does exactly this, and a plugin that
        // opened a document will have no other way to end it (stage 7).
        if ring_focused(a) == nil {
            message_set(a, ":close: nothing is focused")
            return false
        }
        ring_close(a, ring_slot(a))
    case "recover":
        return builtin_recover(a, args)
    case "home":
        ring_add(a, home_open(a))
    case "plug":
        return builtin_plug(a, args)
    case "pluginify":
        return builtin_pluginify(a, args)
    case "q":
        a.quit = true
    case:
        // Past the core set the registry answers, so a plugin's command is typed exactly the
        // way a builtin is and nothing downstream can tell which it was (§12).
        if slot, registered := plug_cmd_named(a, name); registered {
            return plug_command(a, slot, args)
        }
        message_set(a, fmt.tprintf("%s: not a builtin (drop the : to run it in the shell)", name))
        return false
    }
    return true
}

// `:open <path> [slot]`. The slot is an ARGUMENT, which is what makes the routing target
// typed, visible and editable before it commits (§5): `stage :open <path>` puts the line in the
// command line and you aim it there. No routing hook, no display-buffer-alist.
@(private = "file")
builtin_open :: proc(a: ^App, args: string) -> bool {
    raw, path := first_arg(args)
    rest := strings.trim_space(args[len(raw):])
    if path == "" {
        message_set(a, ":open <path> [slot]")
        return false
    }
    slot := 0
    if rest != "" {
        n, ok := strconv.parse_int(rest, 10)
        if !ok || n < 1 {
            message_set(a, ":open: the slot is a number from 1 up")
            return false
        }
        slot = n
    }
    id, ok := open_path(a, path)
    if !ok {
        return false
    }
    if slot == 0 {
        ring_add(a, id)
    } else {
        ring_put(a, id, slot)
    }
    return true
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
builtin_ring :: proc(a: ^App, args: string) -> bool {
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
builtin_ls :: proc(a: ^App) -> bool {
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
builtin_sel :: proc(a: ^App) -> bool {
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
builtin_put :: proc(a: ^App, step: CL_Step) -> bool {
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
builtin_recover :: proc(a: ^App, args: string) -> bool {
    raw, first := first_arg(args)
    drop := first == "drop"
    path := first
    if drop {
        _, path = first_arg(strings.trim_space(args[len(raw):]))
    }
    if path == "" {
        message_set(a, ":recover [drop] <path>")
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

// --- the plugin seam (§7) ---

// `:plug [load|unload|reload] <name>`, and bare `:plug` lists what is in. A plugin is one `.so`
// under `plugins/` beside the binary; the name is its file's stem, and it is also the section
// header its bind requests land under in binds.conf.
@(private = "file")
builtin_plug :: proc(a: ^App, args: string) -> bool {
    raw, verb := first_arg(args)
    _, name := first_arg(strings.trim_space(args[len(raw):]))
    if verb != "" && name == "" {
        message_set(a, ":plug [load|unload|reload] <name>")
        return false
    }
    switch verb {
    case "":
        return plug_list(a)
    case "load":
        return plug_load(a, plug_path(a, name))
    case "unload":
        if i := plug_find(a, name); i >= 0 {
            return plug_unload(a, i)
        }
        message_set(a, fmt.tprintf(":plug: %s is not loaded", name))
        return false
    case "reload":
        return plug_reload(a, name)
    }
    message_set(a, ":plug [load|unload|reload] <name>")
    return false
}

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
            case .Bind, .Watch:
            }
        }
        sys_println(a, fmt.tprintf("%s  %d kind(s), %d command(s)  %s", p.name, kinds, cmds,
                                   p.path))
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
builtin_pluginify :: proc(a: ^App, args: string) -> bool {
    raw, dir := first_arg(args)
    flags := strings.trim_space(args[len(raw):])
    if dir == "" {
        message_set(a, ":pluginify <dir> [--asan]")
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
    script, _ := filepath.join({a.home, PLUGINIFY_SCRIPT}, context.temp_allocator)
    if !os.exists(script) {
        message_set(a, fmt.tprintf(":pluginify: no build script at %s", script))
        return false
    }
    out, _ := filepath.join({a.home, PLUGIN_DIR}, context.temp_allocator)
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

PLUGINIFY_SCRIPT :: "stage.sh"

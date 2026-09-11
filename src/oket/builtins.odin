package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../desc"
import "../shape"
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
     "print every live slot of every lane into N0",
     builtin_ls},
    {"close", "", "ring", USAGE_CLOSE,
     "close the focused slot and the panel with it, or slot N, or the whole lane; a number is never reused while others live",
     builtin_close},
    {"get", "", "ring", USAGE_GET,
     "put a piece of oket's state on the next step's stdin; alone, print it into N0",
     builtin_get},
    {"set", "", "file", USAGE_SET,
     "change one config.conf setting for this session; the file is not written",
     builtin_set},
    {"do", "", "edit", ":do",
     "run what was piped into it, one command line per line, after this chain ends",
     builtin_do},
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
    {"harness", "", "plug", USAGE_HARNESS,
     "run a sequence file in a second oket with the fault net off; a failure names its line",
     builtin_harness},
    {"oket", "", "file", USAGE_OKET,
     "where oket keeps its files, and putting them there or taking them away",
     builtin_oket},
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
    // An alias only lands here unexpanded: it was given arguments, or it hit the depth cap.
    if config_alias_line(&a.config, name) != "" {
        if args != "" {
            message_set(a, fmt.tprintf("%s: an alias takes no arguments", name))
        } else {
            message_set(a, fmt.tprintf("%s: alias expansion is too deep (a cycle?)", name))
        }
        return false
    }
    message_set(a, fmt.tprintf("%s: not a builtin (drop the : to run it in the shell)", name))
    return false
}

// ring.close as a command line. alt+q already does exactly this, and a plugin that opened a
// document will have no other way to end it (stage 7). `#N` closes a slot you are not on, and
// `#*` empties the lane — the slot axis only: what panel stands where is `ring_close`'s own
// fallout, not an argument here.
@(private = "file")
builtin_close :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    target, bad, aimed := target_parse(args)
    if !aimed || target.how != .Here {
        message_set(a, fmt.tprintf(":close: %s is not a slot (%s)", bad != "" ? bad : args,
                                   USAGE_CLOSE))
        return false
    }
    if target.slots {
        return close_lane(a)
    }
    slot := target.slot != 0 ? target.slot : ring_slot(a)
    if ring_get(a, slot) == nil {
        why := ":close: nothing is focused"
        if target.slot != 0 {
            why = fmt.tprintf(":close: #%d holds nothing", slot)
        }
        message_set(a, why)
        return false
    }
    ring_close(a, slot)
    return true
}

// The `#*` arm: every live slot of the focused lane.
@(private = "file")
close_lane :: proc(a: ^App) -> bool {
    lane := ring_lane(a)
    if lane < 0 || lane >= len(a.ring.lanes) {
        message_set(a, ":close: nothing is focused")
        return false
    }
    for i := len(a.ring.lanes[lane].slots); i > 0; i -= 1 {
        if ring_lane(a) != lane {
            break // the lane emptied out and focus fell elsewhere; the rest are gaps
        }
        if lane_get(&a.ring, lane, i) != nil {
            ring_close(a, i)
        }
    }
    return true
}

USAGE_CLOSE :: ":close [#slot|#*]"

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
    if target.how == .All || target.slots {
        message_set(a, ":open: * names every one, and an open needs one place")
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
    // `@*` sizes the strip, one panel at a time: each cycles its own list, so a mixed strip
    // steps every panel to its own next stop rather than to one shared answer.
    if target.how == .All {
        panels_ready(a)
        for i in 0 ..< len(a.panels) {
            panel_width(a, i, pcts[:])
        }
        return true
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

// A percent, or one of the four words for the ones worth a name, as the SHARE the panel keeps
// (panel.odin). The words are exact; a typed number is snapped to an exact fraction when it is
// near one, so `:width 30` is a third and three of them fill the strip.
//
// Out of range is REPORTED and not clamped: a row that says 200 meant something, and sizing it
// to 100 in silence hides it. Checked before the snap, so a number nobody can mean is refused
// rather than rounded into range.
@(private = "file")
width_pct :: proc(field: string) -> (int, bool) {
    switch field {
    case "full":
        return WIDTH_FULL, true
    case "half":
        return WIDTH_FULL / 2, true
    case "third":
        return WIDTH_FULL / 3, true
    case "quarter":
        return WIDTH_FULL / 4, true
    }
    n, num := strconv.parse_int(field, 10)
    share := n * (WIDTH_FULL / 100)
    if !num || share < WIDTH_MIN || share > WIDTH_FULL {
        return share, false
    }
    return width_snap(share), true
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

// The ring, printed into N0, which surfaces to show it.
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
    if !chain_piped(a, step) {
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

// `:get <what>`: a piece of oket's state, one line per thing, the ADDRESS first so an awk or a
// grep downstream has a stable first field. Piped, it is the feed; alone, it prints into N0
// like `:ls`. The verb is what makes a chain conditional without new syntax: the chain already
// branches on a step's exit, so `:get kind | grep -q term && ...` is an if.
@(private = "file")
builtin_get :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    _, what := first_arg(args)
    out, known := get_value(a, what)
    if !known {
        message_set(a, USAGE_GET)
        return false
    }
    chain_feed(a, out)
    if !chain_wants_feed(a) {
        sys_print(a, out)
        ring_show_system(a)
    }
    return true
}

// The one reading of a piece of state, so `:get` and the harness's `!` cannot answer
// differently (AUTHORING.md §6): THE QUERY LANGUAGE IS THE ASSERTION LANGUAGE, and a name added
// for either is answerable by both. Temp-allocated.
get_value :: proc(a: ^App, what: string) -> (string, bool) {
    b := strings.builder_make(context.temp_allocator)
    switch what {
    case "panel":
        panels_ready(a)
        fmt.sbprintf(&b, "%d\n", a.focus + 1)
    case "panels":
        panels_ready(a)
        for &p, i in a.panels {
            if s := panel_slot(a, &p); s != nil {
                fmt.sbprintf(&b, "%d %s %s\n", i + 1, kind_name(a, doc_kind(a, s.doc)),
                             doc_title(a, s.doc))
            } else {
                fmt.sbprintf(&b, "%d -\n", i + 1)
            }
        }
    case "slot":
        fmt.sbprintf(&b, "%s\n", slot_tag(ring_slot(a)))
    case "slots":
        if l := lane_current(a); l != nil {
            for s, i in l.slots {
                if s.live {
                    fmt.sbprintf(&b, "%d %s\n", i + 1, doc_title(a, s.doc))
                }
            }
        }
    case "kind":
        if s := ring_focused(a); s != nil {
            fmt.sbprintf(&b, "%s\n", kind_name(a, doc_kind(a, s.doc)))
        }
    case "file":
        if s := ring_focused(a); s != nil {
            fmt.sbprintf(&b, "%s\n", doc_file(a, s.doc))
        }
    case "message":
        fmt.sbprintf(&b, "%s\n", a.message)
    case "lines":
        if doc := focused_doc(a); doc != nil {
            fmt.sbprintf(&b, "%d\n", txt.text_line_count(&doc.pt))
        }
    case "text":
        if doc := focused_doc(a); doc != nil {
            strings.write_string(&b, txt.doc_string(doc, context.temp_allocator))
        }
    case "desc":
        get_desc(a, &b)
    case "spans":
        get_spans(a, &b)
    case:
        return "", false
    }
    return strings.to_string(b), true
}

USAGE_GET :: ":get panel|panels|slot|slots|kind|file|message|lines|text|desc|spans"

@(private = "file")
focused_doc :: proc(a: ^App) -> ^txt.Doc {
    s := ring_focused(a)
    return s == nil ? nil : store.store_doc(&a.docs, s.doc)
}

// The descriptor, one field one line. Everything the kernel routes and renders by, which is
// exactly the state a plugin's bug is usually IN and the state nothing on screen spells out.
@(private = "file")
get_desc :: proc(a: ^App, b: ^strings.Builder) {
    s := ring_focused(a)
    if s == nil {
        return
    }
    d := store.store_descriptor(&a.docs, s.doc)
    if d == nil {
        return
    }
    defer desc.release(d)
    fmt.sbprintf(b, "render %v\nwrap %v\nnumbers %v\nctx %v\nkind %s\nfile %s\n", d.render,
                 d.wrap, d.numbers, d.ctx, kind_name(a, d.kind), d.file)
    fmt.sbprintf(b, "selection %v\nfollow %v\ninput %v\nmouse %v\neditable %v\ntab_width %d\n",
                 d.selection, d.follow, d.input, d.mouse, d.editable, d.tab_width)
    for c in d.columns {
        fmt.sbprintf(b, "column %s %d %v\n", c.name, c.width, c.align)
    }
    for f in d.fields {
        fmt.sbprintf(b, "field %d %s %d %d %s\n", f.line, f.name, f.lo, f.hi, f.value)
    }
    for n, line in d.depth {
        if n != 0 {
            fmt.sbprintf(b, "depth %d %d\n", line, n)
        }
    }
}

// One run's three channels, in the order `Chan` declares them.
@(private = "file")
span_chan :: proc(sp: store.Span, chan: desc.Chan) -> string {
    switch chan {
    case .Fg:
        return fmt.tprintf("%d", sp.fg)
    case .Bg:
        return fmt.tprintf("%d", sp.bg)
    case .Attrs:
        return span_attrs(sp.attrs)
    }
    return ""
}

@(private = "file")
span_attrs :: proc(attrs: shape.Attrs) -> string {
    b := strings.builder_make(context.temp_allocator)
    for attr in attrs {
        fmt.sbprintf(&b, strings.builder_len(b) == 0 ? "%v" : ",%v", attr)
    }
    return strings.builder_len(b) == 0 ? "none" : strings.to_string(b)
}

// The span store, ONE PUBLISHER AT A TIME. The renderer reads a merged answer and the merge has
// already lost whose run was whose, so a bucket is asked for on its own — the read is
// `store_spans` with an order of length one, which is why this needs nothing new in the store.
@(private = "file")
get_spans :: proc(a: ^App, b: ^strings.Builder) {
    s := ring_focused(a)
    doc := focused_doc(a)
    if s == nil || doc == nil {
        return
    }
    for _, i in a.producers {
        who := store.Producer(i)
        for sp in store.store_spans(&a.docs, s.doc, 0, txt.doc_len(doc), []store.Producer{who}) {
            fmt.sbprintf(b, "%s %d %d", producer_name(a, who), sp.lo, sp.hi)
            // A channel the run has no opinion about is `-` and not a zero: what is under it
            // shows through, and a 0 there would read as a token id (store/spans.odin).
            for chan in desc.Chan {
                fmt.sbprintf(b, " %s", chan not_in sp.set ? "-" : span_chan(sp, chan))
            }
            strings.write_byte(b, '\n')
        }
    }
}

// `:set <section>.<key> <value>`: one config.conf row, typed. It goes through the door the
// file's rows come in (config_set_line), so what it can say and what the file can say cannot
// drift. Session-only — the file is the durable half, and this verb never writes it.
@(private = "file")
builtin_set :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    key := first_field(args)
    value := strings.trim_space(args[len(key):])
    dot := strings.index_byte(key, '.')
    if dot <= 0 || dot + 1 >= len(key) || value == "" {
        message_set(a, USAGE_SET)
        return false
    }
    section, name := key[:dot], key[dot + 1:]
    if !config_set_line(&a.config, section, name, value) {
        message_set(a, fmt.tprintf(":set: %s", config_refusal(section, name)))
        return false
    }
    panels_relayout(a) // gap, tau, behind: the strip reads the config at fit time
    theme_sync(a) // [theme] name loads its file here, not per frame
    return true
}

USAGE_SET :: ":set <section>.<key> <value>"

// `:do` reads the feed as COMMAND LINES and queues them to run after this chain ends — xargs
// for builtins, and the loop the chain itself refuses to grow syntax for: the shell generates
// text, text is commands, and `:get panels | awk ... | :do` walks the strip. Queued rather
// than run here, because a line's parse clears the chain it would be standing in. Lines are
// literal — no holes — since the generator had the values and focus moves as lines run.
@(private = "file")
builtin_do :: proc(a: ^App, _: string, step: CL_Step) -> bool {
    if !chain_piped(a, step) {
        message_set(a, ":do: nothing was piped into it")
        return false
    }
    n := 0
    rest := a.chain.feed
    for line in strings.split_lines_iterator(&rest) {
        if strings.trim_space(line) != "" {
            n += 1
        }
    }
    if len(a.queue) + n > QUEUE_MAX {
        message_set(a, fmt.tprintf(":do: %d lines is past the queue's cap (%d)", n, QUEUE_MAX))
        return false
    }
    rest = a.chain.feed
    for line in strings.split_lines_iterator(&rest) {
        if l := strings.trim_space(line); l != "" {
            append(&a.queue, strings.clone(l))
        }
    }
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

// `:plug [load|unload|reload] <name>`, and bare `:plug` lists what is in. A plugin is a
// DIRECTORY under `plugins/` in the data directory, holding a `.so` of the same name; that name
// is also the section header its bind requests land under in binds.conf.
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
// command line rather than running a compiler itself, so an error lands in N0 where `enter`
// over a `file:line` opens the file. The recipe is plugins/stage.sh and nothing else:
// release.sh and the gate tests run the same script, so this build is the shipped build.
@(private = "file")
builtin_pluginify :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    dir, flags := pluginify_target(a, args)
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
    script := stage_script_path(a)
    if script == "" || (!os.exists(script) && len(STAGE_BAKED) == 0) {
        message_set(a, fmt.tprintf(":pluginify: no build script at %s", script))
        return false
    }
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

// What to build and what to build it with. Named, or — with nothing named — the plugin you are
// LOOKING AT, so the write-build-load loop is one chord over the source you just edited. A file
// resolves to its directory, which is the plugin (§7); a listing already names one.
//
// Split out and reachable so the suite can ask what a line RESOLVES TO without spawning a
// compiler to find out.
pluginify_target :: proc(a: ^App, args: string) -> (dir, flags: string) {
    raw, first := first_arg(args)
    dir, flags = first, strings.trim_space(args[len(raw):])
    if strings.has_prefix(dir, "-") {
        dir, flags = "", strings.trim_space(args)
    }
    if dir != "" {
        return
    }
    if s := ring_focused(a); s != nil {
        dir = doc_file(a, s.doc)
    }
    // Guarded: `filepath.dir("")` answers ".", which would build the working directory.
    if dir != "" && !os.is_dir(dir) {
        dir = filepath.dir(dir) // a slice of dir
    }
    return
}

USAGE_PLUGINIFY :: ":pluginify [<dir>] [--asan]"

// `:harness [<sequence>] [<plugin>...]`: run a repro in a second oket with the fault net
// uninstalled (AUTHORING.md §6). It hands the chain a command line rather than spawning
// anything itself, exactly as `:pluginify` does, so the output lands in N0 where `enter` over a
// `file:line` opens the file — and the file a failure names is the sequence.
//
// With nothing named it runs the file you are LOOKING AT, which is the same rule a bare
// `:pluginify` follows: the loop is one chord over what you just edited.
@(private = "file")
builtin_harness :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    line := harness_line(a, args) or_return
    cl_exec(a, line)
    return true
}

// The command line `:harness` stages, split out and reachable so the suite can ask what a line
// RESOLVES TO without spawning a second oket to read the answer back — the same reason
// `pluginify_target` is not file-private (§8). Temp-allocated, and it is where every refusal is
// worded: the caller returning false over the top of one would lose which refusal it was.
//
// A leading `-` is a flag and goes straight through, which is how `--dump` is reachable from a
// bind row; the first field that is not one is the sequence and the rest are plugins. That is
// `args_paths`'s own reading of a command line, said once more on this side of it.
harness_line :: proc(a: ^App, args: string) -> (string, bool) {
    flags := make([dynamic]string, 0, 2, context.temp_allocator)
    plugs := make([dynamic]string, 0, 4, context.temp_allocator)
    rest, seq := strings.trim_space(args), ""
    for rest != "" {
        raw, value := first_arg(rest)
        rest = strings.trim_space(rest[len(raw):])
        switch {
        case strings.has_prefix(value, "-"):
            if value != HARNESS_DUMP {
                message_set(a, fmt.tprintf(":harness: %s is not a flag it knows", value))
                return "", false
            }
            append(&flags, value)
        case seq == "":
            seq = value
        case:
            append(&plugs, value)
        }
    }
    if seq == "" {
        // The file you are LOOKING AT, the way a bare `:pluginify` builds the plugin you are in.
        if s := ring_focused(a); s != nil {
            seq = doc_file(a, s.doc)
        }
    }
    if seq == "" || !os.exists(seq) {
        message_set(a, fmt.tprintf(":harness: %s", USAGE_HARNESS))
        return "", false
    }
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b, "%s %s", sh_quote(exe_path(context.temp_allocator), context.temp_allocator),
                 HARNESS)
    for flag in flags {
        fmt.sbprintf(&b, " %s", flag)
    }
    fmt.sbprintf(&b, " %s", sh_arg(seq))
    for plug in plugs {
        fmt.sbprintf(&b, " %s", sh_arg(plug))
    }
    return strings.to_string(b), true
}

USAGE_HARNESS :: ":harness [<sequence>] [<plugin>...]"

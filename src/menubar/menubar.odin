package menubar

import "core:slice"
import "core:strings"
import "../input"
import "../menu"

// The menubar's model (MENU.md §3): the bar `src/menu` draws, READ off the tables that are
// already there. A namespace menu is bind rows plus builtin rows, `chords` is the sequence
// space, and a plugin's menu is its ledger — so nothing registers a menu entry and no row can
// name a verb that typing it would not reach.
//
// Built fresh into temp, per frame the menu is up. The bind table changes under a plugin load
// and a binds.conf re-read, and a bar held across either would be showing keys that have moved.

CHORDS :: "chords"

// The opaque `int` a row hands back (`menu.Row.id`). A bind row is its index in `binds`. A `:`
// row is this instead, because its NAME is already the line: `:open <path> [#slot] [@panel]` is
// what the command line stages, holes and all, which is what §5 says `enter` on one does.
STAGE :: -1

Def :: struct {
    name:  string,
    holds: []string, // the verb namespaces it lists
}

// The defaults, so a start with no config draws the same bar (§2).
@(rodata)
DEFAULT := [?]Def {
    {"file", {"file", "cl", "plug"}},
    {"edit", {"edit", "select", "cursor", "search"}},
    {"view", {"view", "nav", "jump", "font"}},
    {"panel", {"panel", "ring"}},
}

// A `:` row: its chord is looked up (`bound`), and a bind row has no usage.
Verb :: struct {
    usage, doc: string,
    menu:       string, // the namespace it sits in
}

Plugin :: struct {
    name: string,
    cmds: []Cmd,
}

Cmd :: struct {
    name, doc: string,
}

// A chord a plugin asked for, parsed. The owner goes on the row rather than over it (§1).
Request :: struct {
    prefix, chord: input.Chord,
    ctx:           input.Bind_Ctx,
    kind:          input.Kind,
    owner:         string,
}

// Everything the bar is read off, for the FOCUSED document's context and kind.
Source :: struct {
    binds:    []input.Bind,
    ctx:      input.Bind_Ctx,
    kind:     input.Kind,
    names:    input.Names,
    layout:   input.Layout_Name,
    menus:    []Def,
    verbs:    []Verb,
    plugins:  []Plugin, // live ones only
    requests: []Request,
}

// The whole bar, the way `bind_children` is: a row the context hides is not in it, so `enter`
// in a browser is a browser row and the editor's is not beside it. The geometry is the
// window's and is put on by the host.
build :: proc(src: Source, allocator := context.temp_allocator) -> menu.Bar {
    menus := make([dynamic]menu.Menu, allocator)
    for d in src.menus {
        append(&menus, menu.Menu{d.name, .Kernel, rows(src, d.holds, allocator)})
    }
    // Absent when no primer is, which is the same rule as no menu for a plugin that is not in:
    // the bar names what is loaded, not what could be.
    if primers := chords(src, allocator); len(primers) > 0 {
        append(&menus, menu.Menu{CHORDS, .Chords, primers})
    }
    for p in src.plugins {
        if len(p.cmds) > 0 {
            append(&menus, menu.Menu{p.name, .Plugin, cmds(src, p.cmds, allocator)})
        }
    }
    return {menus = menus[:]}
}

// One namespace menu: what is bound in it, then what `:` answers for it.
@(private = "file")
rows :: proc(src: Source, holds: []string, allocator := context.temp_allocator) -> []menu.Row {
    out := make([dynamic]menu.Row, allocator)
    for b, i in src.binds {
        if b.prefix != (input.Chord{}) || !answers(src, b) {
            continue
        }
        verb, doc := input.target_info(b.target, src.names)
        if !slice.contains(holds, verb_menu(verb)) {
            continue
        }
        append(&out, menu.Row{
            chord = input.chord_format(b.chord, src.layout, allocator),
            name  = verb,
            doc   = doc,
            id    = i,
        })
    }
    for v in src.verbs {
        if slice.contains(holds, v.menu) {
            name, _, _ := strings.partition(v.usage, " ")
            append(&out, menu.Row{
                chord = bound(src, strings.trim_prefix(name, ":"), allocator),
                name  = v.usage,
                doc   = v.doc,
                id    = STAGE,
            })
        }
    }
    return out[:]
}

// The sequence space (§1): one row per primer, with its children hung off it. A primer has no
// owner — it is declared by its children — so it is listed here once however many plugins are
// under it, and the OWNER is a column on the child rows.
@(private = "file")
chords :: proc(src: Source, allocator := context.temp_allocator) -> []menu.Row {
    out := make([dynamic]menu.Row, allocator)
    seen := make([dynamic]input.Chord, allocator)
    for b in src.binds {
        if b.prefix == (input.Chord{}) || slice.contains(seen[:], b.prefix) {
            continue
        }
        if !input.bind_primes(src.binds, b.prefix, src.ctx, src.kind) {
            continue
        }
        append(&seen, b.prefix)
        append(&out, menu.Row{
            chord = input.chord_format(b.prefix, src.layout, allocator),
            tag   = ">",
            id    = STAGE,
            kids  = kids(src, b.prefix, allocator),
        })
    }
    return out[:]
}

@(private = "file")
kids :: proc(src: Source, prefix: input.Chord, allocator := context.temp_allocator) -> []menu.Row {
    out := make([dynamic]menu.Row, allocator)
    for b, i in src.binds {
        if b.prefix != prefix || !answers(src, b) {
            continue
        }
        verb, _ := input.target_info(b.target, src.names)
        append(&out, menu.Row{
            chord = input.chord_format(b.chord, src.layout, allocator),
            name  = verb,
            tag   = owner(src, b),
            id    = i,
        })
    }
    return out[:]
}

// A plugin's own menu: the commands it registered, typed exactly the way a builtin is. Its bind
// rows are not here — a chord it asked for is under its namespace or under `chords`, and a row
// listed twice would be two answers to one question.
@(private = "file")
cmds :: proc(src: Source, list: []Cmd, allocator := context.temp_allocator) -> []menu.Row {
    out := make([]menu.Row, len(list), allocator)
    for c, i in list {
        out[i] = {
            chord = bound(src, c.name, allocator),
            name  = strings.concatenate({":", c.name}, allocator),
            doc   = c.doc,
            id    = STAGE,
        }
    }
    return out
}

// Shown where a `:` row has no key, so the bind column never collapses out of a menu.
UNBOUND :: "·"

// The key that runs a `:` row's name here, or UNBOUND. A line counts by its first word, so
// `stage :open <path>` is :open's key; a primed row reads as both chords.
@(private = "file")
bound :: proc(src: Source, name: string, allocator := context.temp_allocator) -> string {
    for b in src.binds {
        if runs(b.target, src.names) != name || !answers(src, b) {
            continue
        }
        chord := input.chord_format(b.chord, src.layout, allocator)
        if b.prefix == (input.Chord{}) {
            return chord
        }
        prefix := input.chord_format(b.prefix, src.layout, allocator)
        return strings.concatenate({prefix, " ", chord}, allocator)
    }
    return UNBOUND
}

// The bare `:` name a target runs. A kernel verb is not one: it has its own row.
@(private = "file")
runs :: proc(t: input.Bind_Target, names: input.Names) -> string {
    switch v in t {
    case input.Command:
        return ""
    case input.Slot:
        name, _ := input.target_info(v, names)
        return name
    case input.Bind_Line:
        head, _, _ := strings.partition(string(v), " ")
        return strings.trim_prefix(head, ":")
    }
    return ""
}

// The row a chord REACHES, and not merely one the table holds: binds.conf is PREPENDED over the
// defaults and the row it replaced stays under it, so a menu that listed both would show a key
// doing what it no longer does. This is the question the key handler asks, asked once per row.
@(private = "file")
answers :: proc(src: Source, b: input.Bind) -> bool {
    got, _, ok := input.bind_lookup(src.binds, b.chord, src.ctx, src.kind, b.prefix)
    return ok && got == b
}

// The plugin that asked for a row. Read off the requests: a requested row lands in binds.conf
// and the FILE is its origin from then on, so the table cannot say who wanted it. A row nobody
// asked for is the user's, and names nobody.
@(private = "file")
owner :: proc(src: Source, b: input.Bind) -> string {
    for r in src.requests {
        if r.prefix == b.prefix && r.chord == b.chord && r.kind == b.kind && r.ctx in b.ctx {
            return r.owner
        }
    }
    return ""
}

// The namespace a verb name carries, which is the menu it sits under (§1). A command LINE has
// none: it is text and not a registry name, and `:` rows come from the verbs.
@(private = "file")
verb_menu :: proc(name: string) -> string {
    if strings.has_prefix(name, ":") {
        return ""
    }
    group, dot, _ := strings.partition(name, ".")
    return dot == "" ? "" : group
}

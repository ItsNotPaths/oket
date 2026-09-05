package main

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

MENU_SECTION :: "menu"
MENU_CHORDS :: "chords"

// The opaque `int` a row hands back (`menu.Row.id`). A bind row is its index in `a.binds`. A `:`
// row is this instead, because its NAME is already the line: `:open <path> [#slot] [@panel]` is
// what the command line stages, holes and all, which is what §5 says `enter` on one does.
MENU_STAGE :: -1

Menu_Def :: struct {
    name:  string,
    holds: []string, // the verb namespaces it lists
}

// The defaults, so a start with no config.conf draws the same bar (§2). `[menu] bar` names the
// menus and their order, `[menu] <name>` says what one holds, and both are ordered lists in the
// shape `[<kind>] spans =` already has.
@(rodata)
MENU_DEFAULT := [?]Menu_Def {
    {"file", {"file", "cl", "plug"}},
    {"edit", {"edit", "select", "cursor", "search"}},
    {"view", {"view", "nav", "jump", "font"}},
    {"panel", {"panel", "ring"}},
}

// The whole bar for the FOCUSED document's context and kind, the way `bind_children` is: a row
// the context hides is not in it, so `enter` in a browser is a browser row and the editor's is
// not beside it. The geometry is the frame's and is filled in by the caller (stage 4).
menubar_build :: proc(a: ^App, allocator := context.temp_allocator) -> menu.Bar {
    ctx, kind := bind_ctx(a)
    menus := make([dynamic]menu.Menu, allocator)
    for name in menubar_names(a, allocator) {
        append(&menus, menu.Menu{name, .Kernel, menubar_rows(a, name, ctx, kind, allocator)})
    }
    // Absent when no primer is, which is the same rule as no menu for a plugin that is not in:
    // the bar names what is loaded, not what could be.
    if rows := menubar_chords(a, ctx, kind, allocator); len(rows) > 0 {
        append(&menus, menu.Menu{MENU_CHORDS, .Chords, rows})
    }
    for p, i in a.plugs {
        if !p.live {
            continue
        }
        if rows := menubar_cmds(a, i, allocator); len(rows) > 0 {
            append(&menus, menu.Menu{p.name, .Plugin, rows})
        }
    }
    return {menus = menus[:]}
}

// The menus and their order: the file's list, or the table above.
@(private = "file")
menubar_names :: proc(a: ^App, allocator := context.temp_allocator) -> []string {
    if named := config_names(&a.config, MENU_SECTION, "bar"); len(named) > 0 {
        return named
    }
    out := make([dynamic]string, 0, len(MENU_DEFAULT), allocator)
    for d in MENU_DEFAULT {
        append(&out, d.name)
    }
    return out[:]
}

// The namespaces one menu holds. A menu the file names and says nothing else about holds
// nothing, rather than falling back to a default that is about a different menu.
@(private = "file")
menubar_holds :: proc(a: ^App, name: string) -> []string {
    if named := config_names(&a.config, MENU_SECTION, name); len(named) > 0 {
        return named
    }
    for d in MENU_DEFAULT {
        if d.name == name {
            return d.holds
        }
    }
    return nil
}

// One namespace menu: what is bound in it, then what `:` answers for it. A builtin has no chord
// and a bind row has no usage, so the two fill different columns of the same list.
@(private = "file")
menubar_rows :: proc(a: ^App, name: string, ctx: input.Bind_Ctx, kind: input.Kind,
                     allocator := context.temp_allocator) -> []menu.Row {
    holds := menubar_holds(a, name)
    out := make([dynamic]menu.Row, allocator)
    for b, i in a.binds {
        if b.prefix != (input.Chord{}) || !menubar_answers(a, b, ctx, kind) {
            continue
        }
        verb, doc := input.target_info(b.target, names(a))
        if !slice.contains(holds, verb_menu(verb)) {
            continue
        }
        append(&out, menu.Row{
            chord = input.chord_format(b.chord, key_layout_name, allocator),
            name  = verb,
            doc   = doc,
            id    = i,
        })
    }
    for b in BUILTINS {
        if slice.contains(holds, b.menu) {
            append(&out, menu.Row{name = b.usage, doc = b.doc, id = MENU_STAGE})
        }
    }
    return out[:]
}

// The sequence space (§1): one row per primer, with its children hung off it. A primer has no
// owner — it is declared by its children — so it is listed here once however many plugins are
// under it, and the OWNER is a column on the child rows.
@(private = "file")
menubar_chords :: proc(a: ^App, ctx: input.Bind_Ctx, kind: input.Kind,
                       allocator := context.temp_allocator) -> []menu.Row {
    out := make([dynamic]menu.Row, allocator)
    seen := make([dynamic]input.Chord, allocator)
    for b in a.binds {
        if b.prefix == (input.Chord{}) || slice.contains(seen[:], b.prefix) {
            continue
        }
        if !input.bind_primes(a.binds[:], b.prefix, ctx, kind) {
            continue
        }
        append(&seen, b.prefix)
        append(&out, menu.Row{
            chord = input.chord_format(b.prefix, key_layout_name, allocator),
            tag   = ">",
            id    = MENU_STAGE,
            kids  = menubar_kids(a, b.prefix, ctx, kind, allocator),
        })
    }
    return out[:]
}

@(private = "file")
menubar_kids :: proc(a: ^App, prefix: input.Chord, ctx: input.Bind_Ctx, kind: input.Kind,
                     allocator := context.temp_allocator) -> []menu.Row {
    out := make([dynamic]menu.Row, allocator)
    for b, i in a.binds {
        if b.prefix != prefix || !menubar_answers(a, b, ctx, kind) {
            continue
        }
        verb, _ := input.target_info(b.target, names(a))
        append(&out, menu.Row{
            chord = input.chord_format(b.chord, key_layout_name, allocator),
            name  = verb,
            tag   = menubar_owner(a, b),
            id    = i,
        })
    }
    return out[:]
}

// A plugin's own menu: the commands it registered, typed exactly the way a builtin is. Its bind
// rows are not here — a chord it asked for is under its namespace or under `chords`, and a row
// listed twice would be two answers to one question.
@(private = "file")
menubar_cmds :: proc(a: ^App, owner: int, allocator := context.temp_allocator) -> []menu.Row {
    out := make([dynamic]menu.Row, allocator)
    for c in a.cmds {
        if c.owner != owner {
            continue
        }
        append(&out, menu.Row{
            name = strings.concatenate({":", c.name}, allocator),
            doc  = c.doc,
            id   = MENU_STAGE,
        })
    }
    return out[:]
}

// The row a chord REACHES, and not merely one the table holds: binds.conf is PREPENDED over the
// defaults and the row it replaced stays under it, so a menu that listed both would show a key
// doing what it no longer does. This is the question handle_chord asks, asked once per row.
@(private = "file")
menubar_answers :: proc(a: ^App, b: input.Bind, ctx: input.Bind_Ctx, kind: input.Kind) -> bool {
    got, _, ok := input.bind_lookup(a.binds[:], b.chord, ctx, kind, b.prefix)
    return ok && got == b
}

// The plugin that asked for a row, which §1 puts on the row rather than over it. Read off the
// requests: a requested row lands in binds.conf and the FILE is its origin from then on, so the
// table cannot say who wanted it. A row nobody asked for is the user's, and names nobody.
@(private = "file")
menubar_owner :: proc(a: ^App, b: input.Bind) -> string {
    for r in a.reqs {
        if r.dead {
            continue
        }
        prefix, chord, parsed := input.chord_pair_parse(r.chord, key_layout_code)
        ctx, kind, known := binds_ctx(a, r.ctx)
        if !parsed || !known || prefix != b.prefix || chord != b.chord {
            continue
        }
        if kind == b.kind && ctx in b.ctx {
            return r.owner
        }
    }
    return ""
}

// The namespace a verb name carries, which is the menu it sits under (§1). A command LINE has
// none: it is text and not a registry name, and `:` rows come from the builtin table.
@(private = "file")
verb_menu :: proc(name: string) -> string {
    if strings.has_prefix(name, ":") {
        return ""
    }
    group, dot, _ := strings.partition(name, ".")
    return dot == "" ? "" : group
}

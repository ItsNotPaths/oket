package main

import "../input"
import "../menu"
import "../menubar"

// The menubar model's host (src/menubar): what the bar is read off, as values. `[menu] bar`
// names the menus and their order, `[menu] <name>` says what one holds, and both are ordered
// lists in the shape `[<kind>] spans =` already has.

MENU_SECTION :: "menu"

menubar_build :: proc(a: ^App, allocator := context.temp_allocator) -> menu.Bar {
    ctx, kind := bind_ctx(a)
    return menubar.build({
        binds    = a.binds[:],
        ctx      = ctx,
        kind     = kind,
        names    = names(a),
        layout   = key_layout_name,
        menus    = menubar_defs(a, allocator),
        verbs    = menubar_verbs(allocator),
        plugins  = menubar_plugins(a, allocator),
        requests = menubar_requests(a, allocator),
    }, allocator)
}

// The file's menus, or the defaults. A menu the file names and says nothing else about holds
// nothing, rather than falling back to a default that is about a different menu.
@(private = "file")
menubar_defs :: proc(a: ^App, allocator := context.temp_allocator) -> []menubar.Def {
    named := config_names(&a.config, MENU_SECTION, "bar")
    out := make([]menubar.Def, len(named) > 0 ? len(named) : len(menubar.DEFAULT), allocator)
    for &d, i in out {
        d.name = len(named) > 0 ? named[i] : menubar.DEFAULT[i].name
        d.holds = menubar_holds(a, d.name)
    }
    return out
}

@(private = "file")
menubar_holds :: proc(a: ^App, name: string) -> []string {
    if named := config_names(&a.config, MENU_SECTION, name); len(named) > 0 {
        return named
    }
    for d in menubar.DEFAULT {
        if d.name == name {
            return d.holds
        }
    }
    return nil
}

@(private = "file")
menubar_verbs :: proc(allocator := context.temp_allocator) -> []menubar.Verb {
    out := make([]menubar.Verb, len(BUILTINS), allocator)
    for b, i in BUILTINS {
        out[i] = {b.usage, b.doc, b.menu}
    }
    return out
}

@(private = "file")
menubar_plugins :: proc(a: ^App, allocator := context.temp_allocator) -> []menubar.Plugin {
    out := make([dynamic]menubar.Plugin, allocator)
    for p, i in a.kernel.plugs {
        if p.state != .Live {
            continue
        }
        cmds := make([dynamic]menubar.Cmd, allocator)
        for c in a.kernel.cmds {
            if c.owner == i {
                append(&cmds, menubar.Cmd{c.name, c.doc})
            }
        }
        append(&out, menubar.Plugin{p.name, cmds[:]})
    }
    return out[:]
}

// The live chord requests, parsed. One that no longer parses or names no context owns nothing.
@(private = "file")
menubar_requests :: proc(a: ^App, allocator := context.temp_allocator) -> []menubar.Request {
    out := make([dynamic]menubar.Request, allocator)
    for r in a.kernel.reqs {
        if r.dead {
            continue
        }
        prefix, chord, parsed := input.chord_pair_parse(r.chord, key_layout_code)
        ctx, kind, known := binds_ctx(a, r.ctx)
        if parsed && known {
            append(&out, menubar.Request{prefix, chord, ctx, kind, r.owner})
        }
    }
    return out[:]
}

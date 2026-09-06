package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../input"
import "../menu"
import app "../oket"

// MENU.md §3: the model behind the bar. Every menu here is a READING of a table that is already
// there — the bind table, BUILTINS, the command registry, the requests — so the checks below are
// about what a row SAYS, and none of them registers anything.

// Two plugins, one primer between them, and a command each. The primer is asked for the way a
// plugin asks (a request) and lands the way one lands (a row in the file), because those are two
// halves of one path and the owner column needs both. The third child under the primer is the
// user's own: in the file, asked for by nobody.
@(private = "file")
fixture :: proc(t: ^testing.T) -> (a: app.App, ok: bool) {
    a = bare_app() or_return
    for name in ([?]string{"alpha", "beta"}) {
        append(&a.plugs, app.Plugin{name = strings.clone(name), live = true})
    }
    append(&a.cmds, app.Plug_Cmd{name = strings.clone("alpha.grep"),
                                 doc = strings.clone("search the tree"), owner = 0})
    append(&a.cmds, app.Plug_Cmd{name = strings.clone("beta.tail"),
                                 doc = strings.clone("follow a file"), owner = 1})

    app.binds_request(&a, "alpha", "global", "ctrl+@AB05 ctrl+@AC01", "exec :ls")
    app.binds_request(&a, "beta", "global", "ctrl+@AB05 ctrl+@AC04", "exec :ring")
    app.binds_parse(&a, "[global]\nctrl+@AB05 ctrl+@AC01 = exec :ls\n" +
                        "ctrl+@AB05 ctrl+@AC04 = exec :ring\n" +
                        "ctrl+@AB05 ctrl+@AC02 = exec :sel\n", "binds.conf")
    return a, true
}

@(private = "file")
close :: proc(a: ^app.App) {
    for p in a.plugs {
        delete(p.name)
    }
    delete(a.plugs)
    for c in a.cmds {
        delete(c.name)
        delete(c.doc)
    }
    delete(a.cmds)
    app.home_destroy(&a.home)
    close_app(a)
}

@(private = "file")
named :: proc(b: menu.Bar, name: string) -> (menu.Menu, bool) {
    for m in b.menus {
        if m.name == name {
            return m, true
        }
    }
    return {}, false
}

// A bind row, by its verb.
@(private = "file")
row_named :: proc(rows: []menu.Row, name: string) -> (menu.Row, bool) {
    for r in rows {
        if r.name == name {
            return r, true
        }
    }
    return {}, false
}

// A `:` row, by the verb its usage starts with.
@(private = "file")
row_usage :: proc(rows: []menu.Row, verb: string) -> (menu.Row, bool) {
    for r in rows {
        if strings.has_prefix(r.name, verb) {
            return r, true
        }
    }
    return {}, false
}

@(private = "file")
names_of :: proc(b: menu.Bar, allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, allocator)
    for m in b.menus {
        append(&out, m.name)
    }
    return out[:]
}

// The three regions of §1, in order: the kernel's namespaces, the shared sequence space, then
// one menu per live plugin. The separators the bar draws are read off these and are written
// down nowhere.
@(test)
the_bar_is_namespaces_then_chords_then_a_menu_per_plugin :: proc(t: ^testing.T) {
    a, ok := fixture(t)
    if !ok {
        return
    }
    defer close(&a)

    b := app.menubar_build(&a)
    got := strings.join(names_of(b), " ", context.temp_allocator)
    testing.expect_value(t, got, "file edit view panel chords alpha beta")

    for m in b.menus {
        want := menu.Region.Kernel
        switch m.name {
        case "chords":
            want = .Chords
        case "alpha", "beta":
            want = .Plugin
        }
        testing.expectf(t, m.region == want, "%s is %v, not %v", m.name, m.region, want)
    }

    // A plugin's menu is its ledger and nothing else: the commands it registered, typed the way
    // a builtin is.
    alpha, found := named(b, "alpha")
    testing.expect(t, found)
    testing.expect_value(t, len(alpha.rows), 1)
    testing.expect_value(t, alpha.rows[0].name, ":alpha.grep")
    testing.expect_value(t, alpha.rows[0].doc, "search the tree")
    testing.expect_value(t, alpha.rows[0].id, app.MENU_STAGE)
}

// A menu is a NAMESPACE: what is bound in it, and what `:` answers for it. A builtin row carries
// its usage and its definition, so the menu cannot drift from what a bad parse reports.
@(test)
a_namespace_menu_holds_its_binds_and_its_builtins :: proc(t: ^testing.T) {
    a, ok := fixture(t)
    if !ok {
        return
    }
    defer close(&a)

    b := app.menubar_build(&a)
    file, found := named(b, "file")
    testing.expect(t, found)

    quit, bound := row_named(file.rows, "file.quit")
    testing.expect(t, bound, "the file menu names no file.quit")
    testing.expect(t, quit.chord != "", "a bind row with no chord on it")
    testing.expect(t, quit.doc != "")
    testing.expect(t, quit.id >= 0, "a bind row that does not point back at the table")

    open, listed := row_usage(file.rows, ":open")
    testing.expect(t, listed, "the file menu names no :open")
    testing.expect_value(t, open.chord, "") // a builtin has none until somebody binds one
    testing.expect_value(t, open.id, app.MENU_STAGE)
    testing.expect(t, strings.contains(open.name, "<path>"), open.name)

    // `[menu] panel = panel, ring`, so the ring's builtins are under panel and not under file.
    _, misplaced := row_usage(file.rows, ":ring")
    testing.expect(t, !misplaced, ":ring is under file")
    panel, _ := named(b, "panel")
    _, placed := row_usage(panel.rows, ":ring")
    testing.expect(t, placed, ":ring is under no menu at all")
}

// A primer is declared by its children and belongs to neither of them, so it is one row with
// all of them under it, and each child names the plugin that asked for it. The user's own row
// names nobody.
@(test)
two_owners_under_one_primer_each_name_their_own :: proc(t: ^testing.T) {
    a, ok := fixture(t)
    if !ok {
        return
    }
    defer close(&a)

    b := app.menubar_build(&a)
    chords, found := named(b, "chords")
    testing.expect(t, found, "no chords menu for a table with a primer in it")
    testing.expect_value(t, len(chords.rows), 1) // one primer, however many plugins are under it

    row := chords.rows[0]
    testing.expect(t, row.chord != "")
    testing.expect_value(t, row.name, "") // a primer runs nothing; it pops its children out
    testing.expect_value(t, row.tag, ">")
    testing.expect_value(t, len(row.kids), 3)

    owners := make(map[string]string, 0, context.temp_allocator)
    for kid in row.kids {
        testing.expect(t, kid.chord != "")
        testing.expect(t, kid.id >= 0, "a child that does not point back at the table")
        owners[kid.name] = kid.tag
    }
    testing.expect_value(t, owners[":ls"], "alpha")
    testing.expect_value(t, owners[":ring"], "beta")
    testing.expect_value(t, owners[":sel"], "") // the user's row; no request behind it
}

// The menu is built for the FOCUSED document's context, the way bind_children is. An empty ring
// is Global, and a row written for text is not reachable from there.
@(test)
a_row_the_context_hides_is_absent :: proc(t: ^testing.T) {
    a, ok := fixture(t)
    if !ok {
        return
    }
    defer close(&a)

    b := app.menubar_build(&a)
    edit, found := named(b, "edit")
    testing.expect(t, found)
    _, early := row_named(edit.rows, "edit.cut")
    testing.expect(t, !early, "a text row is listed with nothing focused")

    app.ring_add(&a, scratch_doc(&a, "a.txt", "hello"))
    b = app.menubar_build(&a)
    edit, _ = named(b, "edit")
    cut, late := row_named(edit.rows, "edit.cut")
    testing.expect(t, late, "a text row is hidden with a text document focused")
    testing.expect(t, cut.chord != "")
}

// `chords` is not in `bar` and is not a namespace: it is what the table currently holds. No
// primer, no menu, the same rule as no menu for a plugin that is not in.
@(test)
chords_is_gone_when_no_primer_is :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close(&a)

    b := app.menubar_build(&a)
    _, found := named(b, "chords")
    testing.expect(t, !found, "a chords menu with nothing behind a primer")
    testing.expect_value(t, len(b.menus), 4) // the four kernel namespaces, and no plugin is in
}

// Which menus exist is CONFIG (§2), read through the same parser the rest of config.conf is: a
// section whose every key is an ordered list.
@(test)
the_bar_is_the_lists_the_config_names :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-menubar-config")
    if !made {
        return
    }
    defer os.remove_all(dir)

    a, ok := fixture(t)
    if !ok {
        return
    }
    defer close(&a)

    path, _ := filepath.join({dir, app.CONFIG_NAME}, context.temp_allocator)
    text := "[menu]\nbar = shell, file, extra\nshell = ring\n"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil)
    app.home_set(&a.home, dir)
    app.config_load(&a)

    b := app.menubar_build(&a)
    got := strings.join(names_of(b), " ", context.temp_allocator)
    testing.expect_value(t, got, "shell file extra chords alpha beta")

    // The list is what a menu holds, so a name the file moved moves with it.
    shell, _ := named(b, "shell")
    _, moved := row_usage(shell.rows, ":ring")
    testing.expect(t, moved, ":ring did not follow the list that names it")
    file, _ := named(b, "file")
    _, stayed := row_usage(file.rows, ":open")
    testing.expect(t, stayed, "a menu the file did not name lost its default list")

    // A menu the file names and gives no list holds nothing; no default is about it.
    extra, _ := named(b, "extra")
    testing.expect_value(t, len(extra.rows), 0)
}

// A chord the file re-binds is listed ONCE, saying what it does now: binds.conf is prepended
// over the defaults, so the row it replaced is still in the table under it.
@(test)
a_rebound_chord_is_listed_once_and_says_what_it_runs :: proc(t: ^testing.T) {
    a, ok := bare_app()
    if !ok {
        return
    }
    defer close(&a)
    app.ring_add(&a, scratch_doc(&a, "a.txt", "hello"))

    app.binds_parse(&a, "[text]\nf5 = file.dump\n", "binds.conf")
    b := app.menubar_build(&a)
    file, _ := named(b, "file")

    spelling := input.chord_format(chord_of(t, "f5"), nil, context.temp_allocator)
    saves, stale := 0, false
    for r in file.rows {
        if r.chord != spelling {
            continue
        }
        saves += 1
        stale ||= r.name != "file.dump"
    }
    testing.expect_value(t, saves, 1)
    testing.expect(t, !stale, "the menu lists the row f5 no longer reaches")
}

@(private = "file")
chord_of :: proc(t: ^testing.T, spelling: string) -> input.Chord {
    c, ok := input.chord_parse(spelling, nil)
    testing.expectf(t, ok, "%s is not a chord", spelling)
    return c
}

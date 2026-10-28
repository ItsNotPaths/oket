package main

import "core:fmt"
import "core:strings"
import "lues:conf"
import "../input"

// binds.conf sections as groups (§8). A header may list groups: `[edit] (text)` puts edit
// documents in text. A chord in a document of kind K walks K's rows, then each listed group's in
// order, then `[global]`. Flat: a group's own list is never followed. `send` in a list gives a
// chord nothing claims to the document's own program.

Section :: input.Section

SEC_GLOBAL :: Section(0)
SEC_TEXT :: Section(1)
SEC_SURFACE :: Section(2)
SEC_TERM :: Section(3)
SEC_HOME :: Section(4)
SEC_CMDLINE :: Section(5)

SEND :: "send"

Groups :: struct {
    list: []Section,
    send: bool,
}

// The kernel's sections, by id, with the list each has when the file gives none.
@(rodata)
SECTIONS := [?]struct {
    name:   string,
    groups: Groups,
}{
    {"global", {}},
    {"text", {}},
    {"surface", {}},
    {"term", {send = true}},
    {"home", {{SEC_SURFACE}, true}},
    {"cmdline", {{SEC_TEXT}, false}},
}

// A plugin kind's list when the file gives none, by the string it registered (lues kind_ctx).
@(rodata)
PLUG_GROUPS := [?]struct {
    name:   string,
    groups: Groups,
}{
    {"text", {{SEC_TEXT}, false}},
    {"surface", {{SEC_SURFACE}, true}},
}

// The command line while it starts with that verb.
// (hole verb-tier-delete :tags live :needs (live-whitelist) :sev cleanup) `[:verb]` sections exist only for live find
@(rodata)
VERB_GROUPS := Groups{{SEC_CMDLINE, SEC_TEXT}, false}

section_name :: proc(a: ^App, s: Section) -> string {
    i := int(s)
    if i < len(SECTIONS) {
        return SECTIONS[i].name
    }
    i -= len(SECTIONS)
    return a != nil && i < len(a.sections) ? a.sections[i] : ""
}

// Looked up, never interned: typing a line must not grow the table.
section_find :: proc(a: ^App, name: string) -> (Section, bool) {
    for d, i in SECTIONS {
        if d.name == name {
            return Section(i), true
        }
    }
    for n, i in a.sections {
        if n == name {
            return Section(len(SECTIONS) + i), true
        }
    }
    return SEC_GLOBAL, false
}

section_intern :: proc(a: ^App, name: string) -> Section {
    if s, found := section_find(a, name); found {
        return s
    }
    append(&a.sections, strings.clone(name))
    return Section(len(SECTIONS) + len(a.sections) - 1)
}

// The file's list, else the default for its name.
section_groups :: proc(a: ^App, s: Section) -> Groups {
    if a != nil {
        if g, listed := a.groups[s]; listed {
            return g
        }
    }
    if int(s) < len(SECTIONS) {
        return SECTIONS[s].groups
    }
    if a == nil {
        return {}
    }
    name := section_name(a, s)
    if strings.has_prefix(name, ":") {
        return VERB_GROUPS
    }
    if kind, found := kind_named(a, name); found {
        if k, owned := plug_kind(a, kind); owned && int(k.ctx) < len(PLUG_GROUPS) {
            return PLUG_GROUPS[k.ctx].groups
        }
    }
    return {}
}

// What a chord in this section walks, itself first and global last. Temp-allocated.
section_path :: proc(a: ^App, s: Section) -> (path: []Section, send: bool) {
    g := section_groups(a, s)
    out := make([dynamic]Section, 0, len(g.list) + 2, context.temp_allocator)
    append(&out, s)
    append(&out, ..g.list)
    if s != SEC_GLOBAL {
        append(&out, SEC_GLOBAL)
    }
    return out[:], g.send
}

// No kind is a plain text document; a kind nobody registers any more answers only to global.
kind_section :: proc(a: ^App, kind: input.Kind) -> Section {
    if kind == 0 {
        return SEC_TEXT
    }
    name := kind_name(a, kind)
    return name == "" ? SEC_GLOBAL : section_intern(a, name)
}

// The registered string a plugin kind's default list comes from, as lues stores it.
plug_groups_index :: proc(name: string) -> (u32, bool) {
    for g, i in PLUG_GROUPS {
        if g.name == (name if name != "" else "surface") {
            return u32(i), true
        }
    }
    return 0, false
}

// --- the file's lists ---

// The group lists the file's headers carry, then a warning for any name used only once that no
// kind or built-in answers to: `[fiels]` or a lone `(txt)` is a typo far more often than a group.
binds_groups :: proc(a: ^App, text, origin_name: string) {
    groups_clear(a)
    uses := make(map[string]int, 0, context.temp_allocator)
    first := make(map[string]int, 0, context.temp_allocator)
    use :: proc(uses, first: ^map[string]int, name: string, line: int) {
        if name not_in first^ {
            first[name] = line
        }
        uses[name] += 1
    }
    for h in conf.heads(text) {
        use(&uses, &first, h.section, h.line)
        if h.rest == "" {
            continue
        }
        if why := groups_parse(a, h.section, h.rest); why != "" {
            conf_complain(a, origin_name, h.line, why)
            continue
        }
        for word in strings.fields(h.rest[1:len(h.rest) - 1], context.temp_allocator) {
            use(&uses, &first, word, h.line)
        }
    }
    for name, n in uses {
        if n == 1 && !section_known(a, name) {
            conf_complain(a, origin_name, first[name],
                          fmt.tprintf("%s is used once and is no kind; a typo?", name))
        }
    }
}

// A built-in section, a kind something registered, a `[:verb]`, or `send`.
@(private = "file")
section_known :: proc(a: ^App, name: string) -> bool {
    if name == SEND || strings.has_prefix(name, ":") {
        return true
    }
    if s, found := section_find(a, name); found && int(s) < len(SECTIONS) {
        return true
    }
    _, kind := kind_named(a, name)
    return kind
}

// `(edit text send)`, a flat list of names. "" when it took.
@(private = "file")
groups_parse :: proc(a: ^App, name, list: string) -> string {
    if !strings.has_prefix(list, "(") || !strings.has_suffix(list, ")") {
        return fmt.tprintf("[%s] %s: a group list is written (a b)", name, list)
    }
    s := section_intern(a, name)
    if _, listed := a.groups[s]; listed {
        return fmt.tprintf("[%s] already has a group list; this one is ignored", name)
    }
    g: Groups
    out := make([dynamic]Section)
    for word in strings.fields(list[1:len(list) - 1], context.temp_allocator) {
        switch word {
        case SEND:
            g.send = true
        case "global":
            delete(out)
            return fmt.tprintf("[%s]: global is always last and never listed", name)
        case:
            append(&out, section_intern(a, word))
        }
    }
    g.list = out[:]
    a.groups[s] = g
    return ""
}

groups_clear :: proc(a: ^App) {
    for _, g in a.groups {
        delete(g.list)
    }
    clear(&a.groups)
}

sections_destroy :: proc(a: ^App) {
    groups_clear(a)
    delete(a.groups)
    for n in a.sections {
        delete(n)
    }
    delete(a.sections)
}

// The header the shipped file writes for a section: its list when it has one.
section_header :: proc(a: ^App, s: Section) -> string {
    g := section_groups(a, s)
    words := make([dynamic]string, context.temp_allocator)
    for it in g.list {
        append(&words, section_name(a, it))
    }
    if g.send {
        append(&words, SEND)
    }
    name := section_name(a, s)
    if len(words) == 0 {
        return fmt.tprintf("[%s]", name)
    }
    return fmt.tprintf("[%s] (%s)", name, strings.join(words[:], " ", context.temp_allocator))
}

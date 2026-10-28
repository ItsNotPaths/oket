package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "lues:conf"
import "lues:lues"
import "../input"

// binds.conf (§8). Written complete from the kernel's defaults on a first start and by every
// install; the defaults stay in code as the fallback, and a row the file lacks is reported.
//
//     # --- files ---
//     [files]
//     enter       = stage :open $o_path
//     click       = exec :open $o_path
//     right-click = stage :open $o_path
//
// A section is a bind context: `global`, `text`, `surface`, `terminal`, or a KIND's name —
// `[files]` is narrower than `[surface]` and wins where it applies, which is how `enter` means
// one thing in a listing and another in the editor while both are surfaces. A value is a verb's
// registry name, `none` to unbind, or `exec`/`stage` and a command line whose `$o_`
// names fill from point.
//
// A start never rewrites it, only appends what a plugin asked for. In the config directory, next
// to config.conf (path.odin).

BINDS_NAME :: "binds.conf"

binds_path :: proc(a: ^App) -> string {
    path, _ := filepath.join({a.home.config, BINDS_NAME}, context.temp_allocator)
    return path
}

// --- reading it in ---

// input's defaults, plus the kernel's own kind-narrowed rows. They are here and not in
// `input.binds_default` because a KIND is the kernel's (kinds.odin) and `input` holds one as
// identity it never reads.
binds_base :: proc() -> [dynamic]input.Bind {
    b := input.binds_default()
    // A home-page row is an offer, and `enter` is what takes it: the work a crash left, the
    // plugin that is held back, the file to open. Each row carries the line it runs as `act`, so
    // one row covers every section (home.odin). Narrower than the surface row it shadows, which would
    // open a recovered file and leave the journal sitting beside it (§13).
    input.bind_line(&b, "RTRN", {}, ":do $o_act", ctx = {.Surface}, kind = KIND_HOME)
    // A session's links (term_links.odin). Off a link :openlink selects the word, which is what
    // a double-click did before.
    input.bind_line(&b, "RTRN", {.Alt}, ":openlink", ctx = {.Terminal}, kind = KIND_TERM)
    input.bind_line(&b, "double-click", {}, ":openlink", ctx = {.Terminal}, kind = KIND_TERM)
    return b
}

// Defaults first, the file over them. Called again whenever the set of surface kinds changes,
// because a section may name one.
binds_load :: proc(a: ^App, path: string) {
    input.binds_destroy(&a.binds)
    a.binds = binds_base()
    raw, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return
    }
    binds_parse(a, string(raw), BINDS_NAME)
}

// Split from binds_load so the parse is testable without a filesystem. A bad row is reported and
// skipped; one typo does not cost the file.
binds_parse :: proc(a: ^App, text, origin_name: string) {
    rows, errs := conf.parse(text)
    conf_forget(a, origin_name) // a re-read replaces what the last one found
    for e in errs {
        conf_complain(a, origin_name, e.line, e.why)
    }
    for row in rows {
        section := row.section == "" ? "global" : row.section
        ctx, kind, known := binds_ctx(a, section)
        if !known {
            conf_complain(a, origin_name, row.line,
                           fmt.tprintf("[%s] names no context or surface kind", section))
            continue
        }
        prefix, chord, parsed := input.chord_pair_parse(row.key, key_layout_code)
        if !parsed {
            why := fmt.tprintf("%s is not a chord", row.key)
            if strings.contains(strings.trim_space(row.key), " ") {
                why = fmt.tprintf("%s: a sequence is two chords and both carry a modifier",
                                  row.key)
            }
            conf_complain(a, origin_name, row.line, why)
            continue
        }
        target, made := binds_target(a, row.value)
        if !made {
            conf_complain(a, origin_name, row.line, fmt.tprintf("%s is not a verb", row.value))
            continue
        }
        origin := input.Origin{.Config, strings.clone(origin_name), row.line}
        // Prepended, because bind_scan takes the first match and the defaults are already in: a
        // file row has to be found before the default it is replacing.
        inject_at(&a.binds, 0, input.Bind{chord = chord, prefix = prefix, target = target,
                                          ctx = {ctx}, kind = kind, origin = origin})
    }
}

// The kernel contexts, then `[:verb]`, then the kinds. A kind's section binds in that kind's own
// context and narrows to it, so the two tiers come out of one lookup; a plugin's kind and a verb
// answer through the same lookup.
// (hole kind-chain :tags binds :sev refactor) contexts and kinds are two axes with fixed tiers; one kind chain declared at register, cmdline becomes a pseudo-kind
binds_ctx :: proc(a: ^App, name: string) -> (ctx: input.Bind_Ctx, kind: input.Kind, ok: bool) {
    if c, found := input.ctx_named(name); found {
        return c, 0, true
    }
    if len(name) > 1 && name[0] == ':' {
        token_intern(a, name[1:])
        k, _ := verb_kind(a, name[1:])
        return .Cmdline, k, k != 0
    }
    if k, found := kind_named(a, name); found {
        return kind_ctx(a, k), k, true
    }
    return .Global, 0, false
}

@(rodata)
MODE_WORDS := [input.Bind_Mode]string {
    .Exec  = "exec",
    .Stage = "stage",
}

// A mode word and a command line, `none`, or a verb — a kernel one, or one a plugin registered.
// (hole value-is-line :tags binds :sev refactor) a value is a verb name or exec/stage + line; make it a command line, a lone `:verb` still resolves to the enum at parse
binds_target :: proc(a: ^App, value: string) -> (input.Bind_Target, bool) {
    for word, mode in MODE_WORDS {
        if rest, cut := cut_word(value, word); cut {
            return input.Bind_Line{strings.clone(rest), mode}, true
        }
    }
    if value == input.COMMANDS[.None].name {
        return input.Command.None, true
    }
    if cmd, found := input.command_named(value); found {
        return cmd, true
    }
    if slot, found := plug_cmd_named(a, value); found {
        return slot, true
    }
    return input.Command.None, false
}

// A chord a plugin asked for that the file answers with something else (§8, §13). Derived from
// the LIVE TABLE and never from the writeback: the writeback speaks once per owner — it appends
// a section and never reads it again — so a row it commented out on an earlier start is silent
// on every start after it, which is the one a user is looking at.
//
// A chord bound to `none` is not here. That is the user unbinding it, which is the file
// deciding, and the whole reason a plugin asks rather than claims.
Bind_Unmet :: struct {
    owner: string, // borrowed from the request
    chord: string, // borrowed
    held:  string, // what the chord runs instead; borrowed from the name tables
}

binds_unmet :: proc(a: ^App, allocator := context.temp_allocator) -> []Bind_Unmet {
    out := make([dynamic]Bind_Unmet, allocator)
    for r in a.kernel.reqs {
        if r.dead {
            continue
        }
        ctx, kind, known := binds_ctx(a, r.ctx)
        prefix, chord, parsed := input.chord_pair_parse(r.chord, key_layout_code)
        if !known || !parsed {
            continue
        }
        // bind_at, not bind_lookup: a wider row still leaves this tier free, and the writeback
        // writes the narrow row live.
        b, found := input.bind_at(a.binds[:], chord, ctx, kind, prefix)
        if !found || b.target == input.Bind_Target(input.Command.None) {
            continue
        }
        if held, _ := input.target_info(b.target, names(a)); held != req_line(r.line) {
            append(&out, Bind_Unmet{r.owner, r.chord, held})
        }
    }
    return out[:]
}

// The request without its mode word, which is what a table row holds: `exec :note` is asked
// for, `:note` is bound, and the two are the same row.
@(private = "file")
req_line :: proc(line: string) -> string {
    for word in MODE_WORDS {
        if rest, cut := cut_word(line, word); cut {
            return rest
        }
    }
    return line
}

// A word, never a prefix: a verb called `execute.all` is not a command line.
@(private = "file")
cut_word :: proc(s, word: string) -> (rest: string, ok: bool) {
    if !strings.has_prefix(s, word) || len(s) <= len(word) || s[len(word)] != ' ' {
        return "", false
    }
    return strings.trim_space(s[len(word):]), true
}

// --- writing it back: lues.bind_writeback asks binds_held and binds_shadowed (hooks.bind_held) ---

// What a chord runs on THIS tier, for the clash note. bind_at, not bind_lookup: a resolving
// lookup reads a wider default as a collision and refuses the narrower row that wins at runtime.
binds_held :: proc(a: ^App, ctx_name, chord_text: string) -> (string, bool) {
    ctx, kind, ok := binds_ctx(a, ctx_name)
    prefix, chord, parsed := input.chord_pair_parse(chord_text, key_layout_code)
    if !ok || !parsed {
        return "", false
    }
    b, found := input.bind_at(a.binds[:], chord, ctx, kind, prefix)
    if !found {
        return "", false
    }
    name, _ := input.target_info(b.target, names(a))
    return name, true
}

// What a WIDER tier runs for the chord, once this tier is known to be free. The row is still
// written; this only names what it will cover.
binds_shadowed :: proc(a: ^App, ctx_name, chord_text: string) -> (string, bool) {
    ctx, kind, ok := binds_ctx(a, ctx_name)
    prefix, chord, parsed := input.chord_pair_parse(chord_text, key_layout_code)
    if !ok || !parsed || kind == 0 && ctx == .Global {
        return "", false // nothing is wider than a global row
    }
    b, _, found := input.bind_lookup(a.binds[:], chord, ctx, kind, prefix)
    if !found {
        return "", false
    }
    name, _ := input.target_info(b.target, names(a))
    return name, true
}

// The file first, so a chord the user's own rows hold reads as taken; then what was requested,
// and a re-read only if that changed anything. One path in, so a requested row and a typed row
// are indistinguishable once they are in the table.
binds_sync :: proc(a: ^App) {
    // No home is a test holding an App of its own. Syncing would write beside the test binary,
    // which races the parallel runner and is not this App's file to write.
    if a.home.config == "" {
        input.binds_destroy(&a.binds)
        a.binds = binds_base()
        return
    }
    path := binds_path(a)
    // A directory that cannot be written still HOLDS a binds.conf, and every row in it is live.
    // What a requested row loses is the file to be written down in, and a plugin whose chord is
    // never recorded would ask again at every start.
    writable := home_writable(a.home.config)
    if writable && !os.exists(path) {
        _ = os.write_entire_file(path, transmute([]u8)binds_text(a))
    }
    binds_load(a, path)
    if !writable {
        return
    }
    if lues.bind_writeback(a.kernel, path) {
        binds_load(a, path)
    }
}

// --- the shipped file ---

// Every default as a file row, under its section. What a first start and an install write.
binds_text :: proc(a: ^App) -> string {
    base := binds_base()
    defer input.binds_destroy(&base)
    sections := make([dynamic]string, context.temp_allocator)
    rows := make([dynamic][2]string, context.temp_allocator) // section, row
    for d in base {
        for ctx in d.ctx {
            section, row := binds_row(a, d, ctx)
            if !slice.contains(sections[:], section) {
                append(&sections, section)
            }
            append(&rows, [2]string{section, row})
        }
    }
    b := strings.builder_make(context.temp_allocator)
    for section, i in sections {
        fmt.sbprintf(&b, "%s[%s]\n", i > 0 ? "\n" : "", section)
        for r in rows {
            if r[0] == section {
                fmt.sbprintf(&b, "%s\n", r[1])
            }
        }
    }
    return strings.to_string(b)
}

// The defaults the file has no row for, spelled as the row that would restore each. A `none` row
// counts as there: that chord was unbound on purpose.
binds_missing :: proc(a: ^App, allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, allocator)
    if a.home.config == "" || !os.exists(binds_path(a)) {
        return out[:]
    }
    base := binds_base()
    defer input.binds_destroy(&base)
    for d in base {
        for ctx in d.ctx {
            if !binds_filed(a.binds[:], d, ctx) {
                section, row := binds_row(a, d, ctx)
                append(&out, fmt.aprintf("[%s] %s", section, row, allocator = allocator))
            }
        }
    }
    return out[:]
}

@(private = "file")
binds_filed :: proc(binds: []input.Bind, d: input.Bind, ctx: input.Bind_Ctx) -> bool {
    for b in binds {
        if b.origin.src == .Config && ctx in b.ctx && b.chord == d.chord && b.prefix == d.prefix &&
           b.kind == d.kind {
            return true
        }
    }
    return false
}

@(private = "file")
binds_row :: proc(a: ^App, b: input.Bind, ctx: input.Bind_Ctx) -> (section, row: string) {
    section = b.kind != 0 ? kind_name(a, b.kind) : input.CTX_NAMES[ctx]
    key := chord_spelled(b.chord)
    if b.prefix != {} {
        key = fmt.tprintf("%s %s", chord_spelled(b.prefix), key)
    }
    value: string
    switch t in b.target {
    case input.Command:
        value = input.COMMANDS[t].name
    case input.Slot:
        value, _ = input.target_info(t, names(a))
    case input.Bind_Line:
        value = fmt.tprintf("%s %s", MODE_WORDS[t.mode], t.text)
    }
    return section, fmt.tprintf("%s = %s", key, value)
}

// The layout's spelling when it reads back as the same chord and holds nothing the file reads
// as syntax (`ctrl+=`); the physical one otherwise.
@(private = "file")
chord_spelled :: proc(c: input.Chord) -> string {
    s := input.chord_format(c, key_layout_name, context.temp_allocator)
    if back, ok := input.chord_parse(s, key_layout_code); !ok || back != c || strings.contains_any(s, "=#[") {
        return input.chord_physical(c, context.temp_allocator)
    }
    return s
}

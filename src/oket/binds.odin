package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../conf"
import "../input"

// binds.conf (§8). The kernel's defaults live in code and this file lays over them, so a release
// that adds a verb needs no migration of anybody's file.
//
//     # --- browser ---
//     [browser]
//     enter       = stage :open <path>
//     click       = exec :open <path>
//     right-click = stage :open <path>
//
// A section is a bind context: `global`, `text`, `surface`, `terminal`, or a KIND's name —
// `[files]` is narrower than `[surface]` and wins where it applies, which is how `enter` means
// one thing in a listing and another in the editor while both are surfaces. A value is a verb's
// registry name, or `exec`/`stage`/`pick` and a command line whose `<name>` holes fill from
// point.
//
// Appended, never rewritten: a rewrite would have to re-emit what it read, and that eats
// comments and ordering.

BINDS_NAME :: "binds.conf"

binds_path :: proc(a: ^App) -> string {
    path, _ := filepath.join({a.home, BINDS_NAME}, context.temp_allocator)
    return path
}

// A row something asked for, held until the writeback. A plugin never claims a chord (§8): it
// asks, the row becomes text, and the file decides from then on.
Bind_Request :: struct {
    owner: string, // owned; also the section header it is written under
    ctx:   string, // owned
    chord: string, // owned
    line:  string, // owned
    // The plugin that asked has unloaded. The strings stay owned by this list — what goes is
    // the ASKING, so a later writeback does not put the row back for a plugin that is gone.
    dead:  bool,
}

// A requested chord that met something. `shadows` separates a note from a refusal: a narrower
// row covering a wider one goes in live, a same-tier collision goes in commented out. Neither
// is silent — loud beats last-loaded-wins.
Bind_Clash :: struct {
    owner:   string, // owned
    chord:   string, // owned
    held:    string, // owned; what the chord runs now
    shadows: bool,
}

binds_requests_destroy :: proc(a: ^App) {
    for r in a.reqs {
        delete(r.owner)
        delete(r.ctx)
        delete(r.chord)
        delete(r.line)
    }
    delete(a.reqs)
    a.reqs = nil
    for c in a.clashes {
        delete(c.owner)
        delete(c.chord)
        delete(c.held)
    }
    delete(a.clashes)
    a.clashes = nil
}

// Held, not applied: nothing here touches the live table, which is why two askers cannot race
// and why load order does not decide who wins.
binds_request :: proc(a: ^App, owner, ctx, chord, line: string) {
    if owner == "" || chord == "" || line == "" {
        return
    }
    append(
        &a.reqs,
        Bind_Request {
            strings.clone(owner),
            strings.clone(ctx == "" ? "global" : ctx),
            strings.clone(chord),
            strings.clone(line),
            false,
        },
    )
}

// --- reading it in ---

// input's defaults, plus the kernel's own kind-narrowed rows. They are here and not in
// `input.binds_default` because a KIND is the kernel's (kinds.odin) and `input` holds one as
// identity it never reads.
binds_base :: proc() -> [dynamic]input.Bind {
    b := input.binds_default()
    // A home-page row is a file with unsaved work on it, and `enter` is what takes that work
    // back. Narrower than the surface row it shadows, which would open the file and leave the
    // journal sitting beside it (§13).
    input.bind_line(&b, "RTRN", {}, ":recover <path>", ctx = {.Surface}, kind = KIND_HOME)
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
        chord, parsed := input.chord_parse(row.key, key_layout_code)
        if !parsed {
            conf_complain(a, origin_name, row.line, fmt.tprintf("%s is not a chord", row.key))
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
        inject_at(&a.binds, 0, input.Bind{chord, target, {ctx}, kind, origin, 0})
    }
}

// The four kernel contexts, then the kinds. A kind's section binds in that kind's own context
// and narrows to it, so the two tiers come out of one lookup; a plugin's kind answers through
// the same lookup.
binds_ctx :: proc(a: ^App, name: string) -> (ctx: input.Bind_Ctx, kind: input.Kind, ok: bool) {
    if c, found := input.ctx_named(name); found {
        return c, 0, true
    }
    if k, found := kind_named(a, name); found {
        return kind_ctx(a, k), k, true
    }
    return .Global, 0, false
}

// `exec <line>`, `stage <line>` and `pick <line>` are command lines; anything else names a verb
// — a kernel one, or one a plugin registered. Those three words are the whole grammar.
binds_target :: proc(a: ^App, value: string) -> (input.Bind_Target, bool) {
    if rest, cut := cut_word(value, "exec"); cut {
        return input.Bind_Line{strings.clone(rest), .Exec}, true
    }
    if rest, cut := cut_word(value, "stage"); cut {
        return input.Bind_Line{strings.clone(rest), .Stage}, true
    }
    if rest, cut := cut_word(value, "pick"); cut {
        return input.Bind_Line{strings.clone(rest), .Pick}, true
    }
    if cmd, found := input.command_named(value); found {
        return cmd, true
    }
    if slot, found := plug_cmd_named(a, value); found {
        return slot, true
    }
    return input.Command.None, false
}

// A word, never a prefix: a verb called `execute.all` is not a command line.
@(private = "file")
cut_word :: proc(s, word: string) -> (rest: string, ok: bool) {
    if !strings.has_prefix(s, word) || len(s) <= len(word) || s[len(word)] != ' ' {
        return "", false
    }
    return strings.trim_space(s[len(word):]), true
}

// --- writing it back ---

// The comment that says an owner has been through here. The header is the memory, not the rows
// under it: a user who deletes a row must not have it written back on the next launch, and a
// user who deletes the header is asking for the defaults again.
binds_header :: proc(owner: string) -> string {
    return fmt.tprintf("# --- %s ---", owner)
}

// Appends a section per owner that has none yet. Answers whether the file changed, so the caller
// re-reads rather than guessing.
binds_writeback :: proc(a: ^App, path: string) -> bool {
    if len(a.reqs) == 0 {
        return false
    }
    text := ""
    if raw, err := os.read_entire_file(path, context.temp_allocator); err == nil {
        text = string(raw)
    }
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, text)
    if text != "" && !strings.has_suffix(text, "\n") {
        strings.write_byte(&b, '\n')
    }

    wrote := false
    done := make(map[string]bool, 0, context.temp_allocator)
    // "<ctx> <chord>" already written this run: the table holds neither of two owners asking in
    // the same batch, so the file alone would let the second silently shadow the first.
    seen := make(map[string]string, 0, context.temp_allocator)
    for r in a.reqs {
        if r.dead {
            continue
        }
        if done[r.owner] || strings.contains(text, binds_header(r.owner)) {
            done[r.owner] = true
            continue
        }
        done[r.owner] = true
        fmt.sbprintf(&b, "\n%s\n", binds_header(r.owner))
        binds_write_rows(a, &b, r.owner, &seen)
        wrote = true
    }
    if !wrote {
        return false
    }
    return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}

// One owner's rows, grouped under their section headers, each checked against the table.
@(private = "file")
binds_write_rows :: proc(a: ^App, b: ^strings.Builder, owner: string, seen: ^map[string]string) {
    section := ""
    for row in a.reqs {
        if row.dead || row.owner != owner {
            continue
        }
        if section != row.ctx {
            fmt.sbprintf(b, "[%s]\n", row.ctx)
            section = row.ctx
        }
        key := fmt.tprintf("%s %s", row.ctx, row.chord)
        held, taken := binds_held(a, row.ctx, row.chord)
        if !taken {
            held, taken = seen^[key]
        }
        // A chord held on THIS tier is written commented, never dropped and never stolen:
        // the row is there to uncomment once the other one has moved.
        if taken {
            fmt.sbprintf(b, "# %s = %s   # taken by %s\n", row.chord, row.line, held)
            append(&a.clashes, Bind_Clash{strings.clone(owner), strings.clone(row.chord),
                                          strings.clone(held), false})
            continue
        }
        seen^[key] = owner
        // A wider row still answers this chord elsewhere. The narrow row wins where it
        // applies, so it goes in live — with a note, because the shadow is otherwise
        // invisible. The note gets its own line: a value is read whole, and a command line
        // may contain `#`.
        if over, wider := binds_shadowed(a, row.ctx, row.chord); wider {
            fmt.sbprintf(b, "# shadows %s\n%s = %s\n", over, row.chord, row.line)
            append(&a.clashes, Bind_Clash{strings.clone(owner), strings.clone(row.chord),
                                          strings.clone(over), true})
            continue
        }
        fmt.sbprintf(b, "%s = %s\n", row.chord, row.line)
    }
}

// What a chord runs on THIS tier, for the clash note. bind_at, not bind_lookup: a resolving
// lookup reads a wider default as a collision and refuses the narrower row that wins at runtime.
@(private = "file")
binds_held :: proc(a: ^App, ctx_name, chord_text: string) -> (string, bool) {
    ctx, kind, ok := binds_ctx(a, ctx_name)
    chord, parsed := input.chord_parse(chord_text, key_layout_code)
    if !ok || !parsed {
        return "", false
    }
    b, found := input.bind_at(a.binds[:], chord, ctx, kind)
    if !found {
        return "", false
    }
    name, _ := input.target_info(b.target, names(a))
    return name, true
}

// What a WIDER tier runs for the chord, once this tier is known to be free. The row is still
// written; this only names what it will cover.
@(private = "file")
binds_shadowed :: proc(a: ^App, ctx_name, chord_text: string) -> (string, bool) {
    ctx, kind, ok := binds_ctx(a, ctx_name)
    chord, parsed := input.chord_parse(chord_text, key_layout_code)
    if !ok || !parsed || kind == 0 && ctx == .Global {
        return "", false // nothing is wider than a global row
    }
    b, _, found := input.bind_lookup(a.binds[:], chord, ctx, kind)
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
    if a.home == "" {
        input.binds_destroy(&a.binds)
        a.binds = binds_base()
        return
    }
    path := binds_path(a)
    binds_load(a, path)
    had := len(a.clashes)
    if binds_writeback(a, path) {
        binds_load(a, path)
    }
    refused := 0
    for c in a.clashes[had:] {
        if !c.shadows {
            refused += 1
        }
    }
    if refused > 0 {
        message_set(a, fmt.tprintf("%d requested bind(s) were already taken; see %s",
                                   refused, BINDS_NAME))
    }
}

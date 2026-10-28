package input

import "core:fmt"
import "core:strings"

// The one place a chord is written down, keyed on physical codes. Contexts are declared now
// (the ring and editables arrive in later steps) but only Global has keys to claim yet.

Bind_Ctx :: enum u8 {
    Global,
    Text,
    Surface,
    Terminal,
    // The open command line. Falls back to Text, so a row here only adds to what the line answers.
    Cmdline,
}

Bind_Ctxs :: bit_set[Bind_Ctx;u8]

// A context by its config spelling, the one name binds.conf, `:` and describe all use, so the
// three can never disagree about what a context is called (§6). Enumerated, so
// Odin refuses a literal with a member left out.
@(rodata)
CTX_NAMES := [Bind_Ctx]string {
    .Global   = "global",
    .Text     = "text",
    .Surface  = "surface",
    .Terminal = "terminal",
    .Cmdline  = "cmdline",
}

// What a context falls back to before Global. Itself when it has nothing under it.
ctx_parent :: proc(ctx: Bind_Ctx) -> Bind_Ctx {
    return ctx == .Cmdline ? .Text : ctx
}

ctx_named :: proc(name: string) -> (Bind_Ctx, bool) {
    for n, ctx in CTX_NAMES {
        if n == name {
            return ctx, true
        }
    }
    return .Global, false
}

// The miss rule is data (§6): a context whose documents have a key job of their own takes a
// chord the table does not claim, so copy-versus-kill is a bind and not a mode; everywhere else a
// miss is a no-op.
ctx_forwards :: proc(ctx: Bind_Ctx) -> bool {
    return ctx == .Terminal || ctx == .Surface
}

// A surface kind, opaque here: `input` sits below the registry and never reads it. 0 is every kind, which is what a bind written
// against the plain `surface` context means.
Kind :: distinct u32

// Where a bind came from, so describe answers who bound it and where (§6). There is no
// plugin arm: a plugin's request becomes a file row, so the file is always the origin.
Origin_Src :: enum u8 {
    Kernel,
    Config,
}

Origin :: struct {
    src:  Origin_Src,
    name: string, // owned; the plugin's name or the file's, empty for a kernel default
    line: int, // the file line, 0 when it came from neither
}

Bind :: struct {
    chord:  Chord,
    // The primer this row hides behind, zero for a row that answers on its own. A child is
    // invisible to the scan until its primer is pending, which is a FILTER and not a fallback:
    // nothing retries a miss with the prefix dropped.
    prefix: Chord,
    // What the chord runs, as you would have typed it, with `$o_` names the focused surface fills
    // in (§6). Owned. Empty is `none`: the chord unbound on purpose.
    line:   string,
    ctx:    Bind_Ctxs,
    // Narrower than ctx: a row for one surface kind, which is how `enter` means one thing in a
    // browser and another in the editor while both are Surface. 0 claims every kind.
    kind:   Kind,
    origin: Origin,
}

// Binds own their line text and their origin's name, so the table is freed by proc and not by
// deleting the array.
binds_destroy :: proc(b: ^[dynamic]Bind) {
    for it in b {
        bind_free(it)
    }
    delete(b^)
    b^ = nil
}

bind_free :: proc(b: Bind) {
    delete(b.line)
    delete(b.origin.name)
}

// A kernel default row. Not file-private: the defaults are the kernel's, because a verb and a
// kind are its own and this package holds neither.
bind_line :: proc(b: ^[dynamic]Bind, key: string, mods: Mods, line: string,
                  ctx := Bind_Ctxs{.Global}, kind := Kind(0)) {
    code, ok := key_code(key)
    assert(ok, "a kernel default names a key that is not in the table")
    append(b, Bind{chord = {code, mods}, line = strings.clone(line), ctx = ctx, kind = kind})
}

// A chord that is BOTH a primer and a row of its own. There is no priority between them: the
// scan answers with whichever row it reaches first, so one of the two can never fire. Reported
// rather than resolved — picking a winner here would be a precedence stack, and that is what
// §6 deleted.
Collision :: struct {
    chord: string, // the primer's spelling
    runs:  string, // the verb the plain row on that chord runs
    kids:  int,    // how many rows hide behind it
}

// Every such chord in the table, spelled. Derived on demand and never stored: a row the file
// grew since is in the answer at the next read.
bind_collisions :: proc(binds: []Bind, layout: Layout_Name, names: Names = {},
                        allocator := context.allocator) -> []Collision {
    out := make([dynamic]Collision, allocator)
    for b in binds {
        if b.prefix == (Chord{}) {
            continue
        }
        ctx := bind_one_ctx(b)
        // bind_lookup, not bind_find: a `none` row is a miss, and this report must ask exactly
        // the question handle_chord asks.
        plain, taken := bind_lookup(binds, b.prefix, ctx, b.kind)
        if !taken {
            continue
        }
        spelling := chord_format(b.prefix, layout, allocator)
        if at, seen := collision_at(out[:], spelling); seen {
            out[at].kids += 1
            delete(spelling, allocator)
            continue
        }
        runs, _, _ := line_info(plain.line, names)
        append(&out, Collision{spelling, runs, 1})
    }
    return out[:]
}

collisions_destroy :: proc(c: []Collision, allocator := context.allocator) {
    for it in c {
        delete(it.chord, allocator)
    }
    delete(c, allocator)
}

@(private = "file")
collision_at :: proc(c: []Collision, chord: string) -> (int, bool) {
    for it, i in c {
        if it.chord == chord {
            return i, true
        }
    }
    return 0, false
}

// The context a row answers in, for the callers that need one and not a set. A row carries one
// in practice: the file writes a section, and a default names its verb's.
@(private = "file")
bind_one_ctx :: proc(b: Bind) -> Bind_Ctx {
    for ctx in Bind_Ctx {
        if ctx in b.ctx {
            return ctx
        }
    }
    return .Global
}

// The key that opens the menubar on a primer's own popout (MENU.md §5). Compared as a CHORD
// carrying the primer's modifier — `m-x` reserves `m-space`, `c-f` reserves `c-space` — so
// every chord a primer reserves is modified, exactly like every child it can reach, and an
// unmodified key under a primer always types.
//
// Space, because the one key that must work under EVERY primer cannot be a letter a plugin
// wants for a mnemonic, and because it is the same position on every layout.
PREFIX_HELP :: "SPCE"

// A primer is declared by its CHILDREN and by nothing else: no `ctrl+b = prefix` row to keep in
// step, and deleting the last child is what ends the primer. So arming asks the table whether
// any row hides behind this chord, in a context the keys can currently reach.
bind_primes :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0) -> bool {
    for b in binds {
        if b.prefix == chord && bind_reachable(b, ctx, kind) {
            return true
        }
    }
    return false
}

// The tiers bind_find would walk, as a predicate: this row's own kind, its context, or Global.
// Package-wide, because a reader asking what a DOCUMENT can do walks the table with it rather
// than writing the tiers down a second time (the kernel's link renderer).
bind_reachable :: proc(b: Bind, ctx: Bind_Ctx, kind: Kind) -> bool {
    if b.kind != 0 {
        return b.kind == kind && ctx in b.ctx
    }
    return b.ctx & {ctx, ctx_parent(ctx), .Global} != {}
}

// The children of a primer, spelled `chord verb` and joined, for the label the bar shows. Capped
// by the caller's budget rather than here, because what fits is the bar's question.
bind_children :: proc(binds: []Bind, prefix: Chord, ctx: Bind_Ctx, layout: Layout_Name,
                      names: Names = {}, kind: Kind = 0,
                      allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for it in binds {
        if it.prefix != prefix || !bind_reachable(it, ctx, kind) {
            continue
        }
        if strings.builder_len(b) > 0 {
            strings.write_string(&b, "  ")
        }
        name, _, _ := line_info(it.line, names)
        fmt.sbprintf(&b, "%s %s", chord_format(it.chord, layout, context.temp_allocator), name)
    }
    return strings.to_string(b)
}

// Narrowest row wins: one written for this surface kind, then one for the context, then a
// Global one (`esc = surface.send` shadows the global quit). First exact match inside a tier.
bind_find :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0,
                  prefix := Chord{}) -> (Bind, bool) {
    if kind != 0 {
        if b, ok := bind_scan(binds, chord, {ctx}, kind, prefix); ok {
            return b, true
        }
    }
    for c in ([2]Bind_Ctx{ctx, ctx_parent(ctx)}) {
        if c == .Global {
            break
        }
        if b, ok := bind_scan(binds, chord, {c}, 0, prefix); ok {
            return b, true
        }
    }
    return bind_scan(binds, chord, {.Global}, 0, prefix)
}

@(private = "file")
bind_scan :: proc(binds: []Bind, chord: Chord, want: Bind_Ctxs, kind: Kind,
                  prefix := Chord{}) -> (Bind, bool) {
    for b in binds {
        if b.prefix == prefix &&
           b.chord == chord &&
           b.kind == kind &&
           b.ctx & want != {} {
            return b, true
        }
    }
    return {}, false
}

// One tier, no fallthrough: is THIS ctx-and-kind already holding the chord. The clash check
// wants this and not bind_lookup, because a narrower row shadowing a wider one is the feature
// (§6) and a resolving lookup reports it as a collision.
bind_at :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0,
                prefix := Chord{}) -> (Bind, bool) {
    return bind_scan(binds, chord, {ctx}, kind, prefix)
}

// A shifted chord is its own row: shift+down extends because a row says `:nav.down extend`.
bind_lookup :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx, kind: Kind = 0,
                    prefix := Chord{}) -> (Bind, bool) {
    b, ok := bind_find(binds, chord, ctx, kind, prefix)
    // `none` unbinds on purpose: the tier answers, and what it answers is a miss.
    if !ok || b.line == "" {
        return {}, false
    }
    return b, true
}

// The host's reading of a line and of a kind, lent by the caller: `input` holds a line as text
// and a Kind as identity and never the tables that name either (§6). A zero value names nothing,
// and every reader below stays total without it.
Names :: struct {
    user: rawptr,
    // A verb's name and doc for a line that names one, and whether it places its own point.
    line: proc(user: rawptr, line: string) -> (name, doc: string, places_point: bool),
    kind: proc(user: rawptr, kind: Kind) -> string,
}

line_info :: proc(line: string, names: Names) -> (name, doc: string, places_point: bool) {
    if names.line != nil {
        return names.line(names.user, line)
    }
    return line, "run as typed", false
}

// `kernel default`, `binds.conf:14` — the half of describe that answers who bound this,
// which is the Emacs failure the whole facility exists to prevent (§6).
origin_label :: proc(o: Origin) -> string {
    switch o.src {
    case .Kernel:
        return "kernel default"
    case .Config:
        return o.line > 0 ? fmt.tprintf("%s:%d", o.name, o.line) : o.name
    }
    return "?"
}

// Total over chords: every code, named or not, bound or not, gets an answer (§6). The layout
// spelling first, the physical spelling always, then what it runs and who bound it.
describe_chord :: proc(
    binds: []Bind,
    chord: Chord,
    ctx: Bind_Ctx,
    layout: Layout_Name,
    names: Names = {},
    kind: Kind = 0,
    allocator := context.allocator,
) -> string {
    spelling := chord_format(chord, layout, context.temp_allocator)
    phys := chord_physical(chord, context.temp_allocator)
    if spelling == phys { // a nameless code has only the one spelling
        phys = ""
    } else {
        phys = fmt.tprintf(" (%s)", phys)
    }

    // A button chord moves point whether or not a row claims it, so an unbound one is still
    // not a no-op and describe must not call it unbound (§8).
    moves_point := false
    if m, is_mouse := mouse_of(chord.code); is_mouse {
        moves_point = mouse_moves_point(m)
    }

    b, bound := bind_lookup(binds, chord, ctx, kind)
    if !bound {
        if moves_point {
            return fmt.aprintf(
                "%s moves point; nothing further is bound",
                spelling,
                allocator = allocator,
            )
        }
        // A primer is a row's PREFIX and never a row, so the lookup above misses it and
        // describe would call the chord unbound. It reads its children out instead.
        if bind_primes(binds, chord, ctx, kind) {
            kids := bind_children(binds, chord, ctx, layout, names, kind, context.temp_allocator)
            return fmt.aprintf("%s%s arms a primer: %s", spelling, phys, kids,
                               allocator = allocator)
        }
        if ctx_forwards(ctx) {
            return fmt.aprintf("%s%s is unbound, falls through to the document's own job",
                               spelling, phys, allocator = allocator)
        }
        return fmt.aprintf("%s%s is unbound", spelling, phys, allocator = allocator)
    }
    name, doc, places := line_info(b.line, names)
    if places {
        moves_point = false
    }
    // The tier the row actually won on. A kind row is narrower than its context, and saying
    // `surface` for one would be describe lying about which of two rows answered.
    claimed := CTX_NAMES[ctx in b.ctx ? ctx : ctx_parent(ctx) in b.ctx ? ctx_parent(ctx) : .Global]
    if b.kind != 0 && names.kind != nil {
        if n := names.kind(names.user, b.kind); n != "" {
            claimed = n
        }
    }
    verb := "runs"
    if moves_point {
        verb = fmt.tprintf("moves point, then %s", verb)
    }
    return fmt.aprintf(
        "%s%s %s %s: %s [%s, %s]",
        spelling,
        phys,
        verb,
        name,
        doc,
        claimed,
        origin_label(b.origin),
        allocator = allocator,
    )
}

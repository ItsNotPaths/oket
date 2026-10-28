package input

import "core:fmt"
import "core:slice"
import "core:strings"

// The one place a chord is written down, keyed on physical codes.

// A binds.conf section, interned by the host: a kind, a group or global. `input` never reads a
// name; a lookup walks the sections the host lists, narrowest first.
Section :: distinct u32

// A document kind, opaque here: what a descriptor names and the host maps to its section.
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
    chord:   Chord,
    // The primer this row hides behind, zero for a row that answers on its own. A child is
    // invisible to the scan until its primer is pending, which is a FILTER and not a fallback:
    // nothing retries a miss with the prefix dropped.
    prefix:  Chord,
    // What the chord runs, as you would have typed it, with `$o_` names the focused surface fills
    // in (§6). Owned. Empty is `none`: the chord unbound on purpose.
    line:    string,
    section: Section,
    origin:  Origin,
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
bind_line :: proc(b: ^[dynamic]Bind, key: string, mods: Mods, line: string, section: Section) {
    code, ok := key_code(key)
    assert(ok, "a kernel default names a key that is not in the table")
    append(b, Bind{chord = {code, mods}, line = strings.clone(line), section = section})
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
        // bind_lookup, not bind_find: a `none` row is a miss, and this report must ask exactly
        // the question handle_chord asks.
        plain, taken := bind_lookup(binds, b.prefix, names_path(names, b.section))
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
// any row hides behind this chord, in a section the keys can currently reach.
bind_primes :: proc(binds: []Bind, chord: Chord, path: []Section) -> bool {
    for b in binds {
        if b.prefix == chord && slice.contains(path, b.section) {
            return true
        }
    }
    return false
}

// The children of a primer, spelled `chord verb` and joined, for the label the bar shows. Capped
// by the caller's budget rather than here, because what fits is the bar's question.
bind_children :: proc(binds: []Bind, prefix: Chord, path: []Section, layout: Layout_Name,
                      names: Names = {}, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for it in binds {
        if it.prefix != prefix || !slice.contains(path, it.section) {
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

// The first section on the path holding the chord answers; first match inside a section.
bind_find :: proc(binds: []Bind, chord: Chord, path: []Section,
                  prefix := Chord{}) -> (Bind, bool) {
    for s in path {
        if b, ok := bind_at(binds, chord, s, prefix); ok {
            return b, true
        }
    }
    return {}, false
}

// One section, no fallthrough. The clash check wants this and not bind_lookup, because a
// narrower row shadowing a wider one is the feature (§6).
bind_at :: proc(binds: []Bind, chord: Chord, section: Section,
                prefix := Chord{}) -> (Bind, bool) {
    for b in binds {
        if b.prefix == prefix && b.chord == chord && b.section == section {
            return b, true
        }
    }
    return {}, false
}

// A shifted chord is its own row: shift+down extends because a row says `:nav.down extend`.
bind_lookup :: proc(binds: []Bind, chord: Chord, path: []Section,
                    prefix := Chord{}) -> (Bind, bool) {
    b, ok := bind_find(binds, chord, path, prefix)
    // `none` unbinds on purpose: the section answers, and what it answers is a miss.
    if !ok || b.line == "" {
        return {}, false
    }
    return b, true
}

// The host's reading of a line and of a section, lent by the caller: `input` holds both as
// identity and never the tables that name them (§6). A zero value names nothing, and every
// reader below stays total without it.
Names :: struct {
    user:    rawptr,
    // A verb's name and doc for a line that names one, and whether it places its own point.
    line:    proc(user: rawptr, line: string) -> (name, doc: string, places_point: bool),
    section: proc(user: rawptr, s: Section) -> string,
    // The sections a chord in this one walks, itself first.
    path:    proc(user: rawptr, s: Section) -> []Section,
}

names_path :: proc(names: Names, s: Section) -> []Section {
    if names.path != nil {
        return names.path(names.user, s)
    }
    return slice.clone([]Section{s}, context.temp_allocator)
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
    path: []Section,
    sends: bool, // an unclaimed chord goes to the document's own program
    layout: Layout_Name,
    names: Names = {},
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

    b, bound := bind_lookup(binds, chord, path)
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
        if bind_primes(binds, chord, path) {
            kids := bind_children(binds, chord, path, layout, names, context.temp_allocator)
            return fmt.aprintf("%s%s arms a primer: %s", spelling, phys, kids,
                               allocator = allocator)
        }
        if sends {
            return fmt.aprintf("%s%s is unbound, falls through to the document's own job",
                               spelling, phys, allocator = allocator)
        }
        return fmt.aprintf("%s%s is unbound", spelling, phys, allocator = allocator)
    }
    name, doc, places := line_info(b.line, names)
    if places {
        moves_point = false
    }
    // The section the row actually won on, so describe never names the wrong one of two rows.
    claimed := fmt.tprintf("%d", b.section)
    if names.section != nil {
        if n := names.section(names.user, b.section); n != "" {
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

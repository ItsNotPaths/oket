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
//     enter       = :stage :open $o_path
//     click       = :open $o_path
//     up          = :fs.up.row
//
// A section is a bind context: `global`, `text`, `surface`, `terminal`, or a KIND's name —
// `[files]` is narrower than `[surface]` and wins where it applies, which is how `enter` means
// one thing in a listing and another in the editor while both are surfaces. A value is a command
// line whose `$o_` names fill from point, or `none` to unbind.
//
// A start never rewrites it, only appends what a plugin asked for. In the config directory, next
// to config.conf (path.odin).

BINDS_NAME :: "binds.conf"

binds_path :: proc(a: ^App) -> string {
    path, _ := filepath.join({a.home.config, BINDS_NAME}, context.temp_allocator)
    return path
}

// --- reading it in ---

// The kernel's default rows, each a command line. Letter chords are POSITIONS, so a layout swap
// keeps them under the same fingers.
binds_base :: proc() -> [dynamic]input.Bind {
    b := make([dynamic]input.Bind)
    input.bind_line(&b, "ESC", {}, ":file.quit", {.Global})
    input.bind_line(&b, "FK01", {}, ":describe.key", {.Global})

    // Bare arrows move point in a SURFACE as well as in text: a listing's up and down is the
    // same point move, and nothing else claims an unmodified arrow there. Ctrl and Alt arrows
    // stay narrower, which is what leaves the terminal its own.
    //
    // Letter chords are POSITIONS (QWERTY letters name them below); a layout swap keeps them
    // under the same fingers.
    bind_motion(&b, "UP", {}, "nav.up", {.Text, .Surface})
    bind_motion(&b, "DOWN", {}, "nav.down", {.Text, .Surface})
    bind_motion(&b, "LEFT", {}, "nav.left", {.Text, .Surface})
    bind_motion(&b, "RGHT", {}, "nav.right", {.Text, .Surface})
    bind_motion(&b, "LEFT", {.Ctrl}, "edit.word_left", {.Text})
    bind_motion(&b, "RGHT", {.Ctrl}, "edit.word_right", {.Text})
    bind_motion(&b, "HOME", {}, "edit.home", {.Text})
    bind_motion(&b, "END", {}, "edit.end", {.Text})
    bind_motion(&b, "HOME", {.Ctrl}, "edit.doc_start", {.Text})
    bind_motion(&b, "END", {.Ctrl}, "edit.doc_end", {.Text})
    bind_motion(&b, "UP", {.Ctrl}, "edit.para_up", {.Text})
    bind_motion(&b, "DOWN", {.Ctrl}, "edit.para_down", {.Text})
    input.bind_line(&b, "BKSP", {}, ":edit.delete_back", {.Text})
    input.bind_line(&b, "BKSP", {.Shift}, ":edit.delete_back", {.Text}) // shift still down from a capital
    input.bind_line(&b, "DELE", {}, ":edit.delete_forward", {.Text})
    input.bind_line(&b, "BKSP", {.Ctrl}, ":edit.delete_word_back", {.Text})
    input.bind_line(&b, "DELE", {.Ctrl}, ":edit.delete_word_forward", {.Text})
    input.bind_line(&b, "RTRN", {}, ":edit.newline", {.Text})
    input.bind_line(&b, "RTRN", {.Shift}, ":edit.newline", {.Text})
    input.bind_line(&b, "KPEN", {}, ":edit.newline", {.Text})
    input.bind_line(&b, "TAB", {}, ":edit.tab", {.Text})
    // The placement verbs (VIEWS.md §4). A caret is PLACED, not walked to, which is why there is
    // no prefix key and no armed mode here: each row says where the next caret goes, and the
    // arrows above already move the whole set. `cursor.split_lines` keeps no default chord and
    // `cursor.collapse` needs none — Escape answers it ahead of every row that claims the key,
    // for exactly as long as a trail is up.
    input.bind_line(&b, "DOWN", {.Ctrl, .Alt}, ":cursor.add_below", {.Text, .Surface})
    input.bind_line(&b, "UP", {.Ctrl, .Alt}, ":cursor.add_above", {.Text, .Surface})
    input.bind_line(&b, "AC03", {.Alt}, ":cursor.add_next_match", {.Text, .Surface}) // alt+d
    input.bind_line(&b, "AC03", {.Alt, .Shift}, ":cursor.add_all_matches", {.Text, .Surface})
    // The mouse row costs nothing, because a button is already a chord (§8).
    input.bind_line(&b, "click", {.Alt}, ":cursor.add", {.Text, .Surface})

    // ctrl+a and ctrl+e are the most deployed pair there is: every readline prompt and every
    // Cocoa text field. Arrows already carry motion, so the only cost is select-all, which
    // stays a verb with no default chord (Emacs gives it none either).
    bind_motion(&b, "AC01", {.Ctrl}, "edit.home", {.Text}) // ctrl+a
    bind_motion(&b, "AD03", {.Ctrl}, "edit.end", {.Text}) // ctrl+e
    input.bind_line(&b, "AC02", {.Ctrl}, ":file.dump", {.Text, .Surface}) // ctrl+s
    input.bind_line(&b, "AB01", {.Ctrl}, ":edit.undo", {.Text, .Surface}) // ctrl+z
    input.bind_line(&b, "AB01", {.Ctrl, .Shift}, ":edit.redo", {.Text, .Surface}) // a different verb, so Shift is written out
    input.bind_line(&b, "FK03", {}, ":search.next", {.Text, .Surface})
    input.bind_line(&b, "FK03", {.Shift}, ":search.prev", {.Text, .Surface})

    // The modern spelling, not Emacs's C-w/M-w/C-y: C-w is the close-window reflex everywhere
    // else. The kill RING is Emacs's — ctrl+shift+v walks it, yank-pop under a guessable name.
    // All {.Text, .Surface} and never {.Global}, so a terminal answers for its own: ctrl+c there
    // is `term.copy` and the interrupt is ctrl+shift+c (see the terminal rows below).
    input.bind_line(&b, "AB02", {.Ctrl}, ":edit.cut", {.Text, .Surface}) // ctrl+x
    input.bind_line(&b, "AB03", {.Ctrl}, ":edit.copy", {.Text, .Surface}) // ctrl+c
    input.bind_line(&b, "AB04", {.Ctrl}, ":edit.paste", {.Text, .Surface}) // ctrl+v
    input.bind_line(&b, "AB04", {.Ctrl, .Shift}, ":edit.paste_cycle", {.Text, .Surface})
    input.bind_line(&b, "AC08", {.Ctrl}, ":edit.kill_line", {.Text, .Surface}) // ctrl+k
    input.bind_line(&b, "AC08", {.Ctrl, .Shift}, ":edit.kill_whole_line", {.Text, .Surface})
    input.bind_line(&b, "AD07", {.Ctrl}, ":edit.kill_to_line_start", {.Text, .Surface}) // ctrl+u, readline's unix-line-discard

    for n in 1 ..= 9 {
        input.bind_line(&b, fmt.tprintf("AE%02d", n), {.Alt}, fmt.tprintf(":ring.goto %d", n))
    }
    input.bind_line(&b, "TLDE", {.Alt}, ":ring.alt", {.Global}) // alt+` sits at the number row's door
    input.bind_line(&b, "TLDE", {.Alt, .Shift}, ":ring.alt_lane", {.Global}) // and Shift keeps it in one ring
    input.bind_line(&b, "AD01", {.Alt}, ":ring.close", {.Global}) // alt+q
    input.bind_line(&b, "AE10", {.Alt}, ":ring.zero", {.Global}) // alt+0: at the rotation's edge, not in it (§11)
    // The strip (PANELS.md §3, §5). Alt keeps meaning "move between things": the numbers walk
    // the ring, and the side arrows walk the panels. Ctrl on the same two walks the JUMP ring,
    // which is the third thing you move between; their vertical twins are already the placement
    // verbs above, so the whole ctrl+alt cross reads as one family.
    input.bind_line(&b, "LEFT", {.Alt}, ":panel.prev", {.Global})
    input.bind_line(&b, "RGHT", {.Alt}, ":panel.next", {.Global})
    // Shift on the walk MOVES what you are looking at, which is the pairing every strip and
    // tab bar already uses.
    input.bind_line(&b, "LEFT", {.Alt, .Shift}, ":panel.move_left", {.Global})
    input.bind_line(&b, "RGHT", {.Alt, .Shift}, ":panel.move_right", {.Global})
    input.bind_line(&b, "LEFT", {.Ctrl, .Alt}, ":jump.back", {.Global})
    input.bind_line(&b, "RGHT", {.Ctrl, .Alt}, ":jump.forward", {.Global})
    input.bind_line(&b, "AD10", {.Alt}, ":panel.open", {.Global}) // alt+p
    input.bind_line(&b, "AD10", {.Alt, .Shift}, ":panel.close", {.Global}) // the panel, never the document in it
    // alt+w, for width. A LINE, because the sizing model is the row and not the kernel: rebind
    // the list and the same key is a toggle, a three-way or a set.
    input.bind_line(&b, "AD02", {.Alt}, ":width 30 50 100")
    input.bind_line(&b, "AC09", {.Alt}, ":lock") // alt+l
    // The universal spelling, and it moves the TEXT rather than the grid: ctrl+= is bigger
    // glyphs, which is fewer cells.
    input.bind_line(&b, "AE12", {.Ctrl}, ":font.bigger", {.Global}) // ctrl+=
    input.bind_line(&b, "AE11", {.Ctrl}, ":font.smaller", {.Global}) // ctrl+-
    input.bind_line(&b, "AE10", {.Ctrl}, ":font.reset", {.Global}) // ctrl+0
    input.bind_line(&b, "AB03", {.Alt}, ":cl.open", {.Global}) // alt+c
    input.bind_line(&b, "AC10", {.Alt}, ":cl.sigil", {.Global}) // alt+;
    // alt+space; under a primer the same key carries THAT primer's modifier (MENU.md §5).
    input.bind_line(&b, input.PREFIX_HELP, {.Alt}, ":menu.open", {.Global})

    // Switching lanes is its own key, not a walk through the numbers (§5). These are LINES, so
    // the kind is named in a command line the user can read and rebind, and never in a case in
    // the dispatch — which is the whole reason `:ring` exists as a builtin.
    input.bind_line(&b, "AD03", {.Alt}, ":ring edit") // alt+e
    input.bind_line(&b, "AC04", {.Alt}, ":ring files") // alt+f
    input.bind_line(&b, "AD05", {.Alt}, ":ring term") // alt+t
    // alt+. — the lane switch for every OTHER kind, which is a plugin's and so has no letter of
    // its own here. Staged rather than run: the line is `:ring` with the name left to type, and a
    // bare `:ring` lists the lanes.
    input.bind_line(&b, "AB09", {.Alt}, ":stage :ring")
    // A listing's rows are paths, and `enter` is what opens one. Written at the SURFACE tier
    // rather than for one kind: a surface whose lines carry no `path` reports that it cannot
    // fill `$o_path`, which is data rather than a refusal decided per call (§8).
    input.bind_line(&b, "RTRN", {}, ":open $o_path", {.Surface})
    // The same open, one panel over. §6: the direction preference is a ROW and not a config
    // key, because a row is greppable, rebindable and describable.
    input.bind_line(&b, "RTRN", {.Ctrl}, ":open $o_path @-1", {.Surface})

    // The mouse, as ordinary rows (§8). A button chord has none: the kernel moves point before
    // it dispatches one, so `click` with nothing bound already does the thing a click does, and
    // a row is what a surface adds to make it do more.
    input.bind_line(&b, "double-click", {}, ":select.expand", {.Text, .Surface})
    input.bind_line(&b, "wheel-up", {}, ":view.scroll_up", {.Global})
    input.bind_line(&b, "wheel-down", {}, ":view.scroll_down", {.Global})

    // Surface claims: context-specific, so they shadow the global rows above (Esc must reach
    // vim inside the shell, never quit oket).
    input.bind_line(&b, "ESC", {}, ":surface.send", {.Terminal, .Surface})
    // ctrl+c and ctrl+v copy and paste HERE TOO, so one chord means one thing in every document,
    // and ctrl+shift+v pastes as every other terminal's does. The interrupt is
    // ctrl+shift+c: it sends the 0x03 a shell reads as SIGINT, narrowed to the terminal so no
    // other surface claims the chord. Both are ordinary rows, so a binds.conf that swaps them
    // back is two lines.
    input.bind_line(&b, "AB03", {.Ctrl}, ":term.copy", {.Terminal}) // ctrl+c
    input.bind_line(&b, "AB03", {.Ctrl, .Shift}, ":surface.send", {.Terminal})
    input.bind_line(&b, "AB04", {.Ctrl}, ":term.paste", {.Terminal}) // ctrl+v
    input.bind_line(&b, "AB04", {.Ctrl, .Shift}, ":term.paste", {.Terminal})
    // Scrolling a session is the KERNEL's viewport over its document (§11), so these are the
    // same two verbs every other document has and there is no terminal scroll code to bind to.
    input.bind_line(&b, "PGUP", {.Shift}, ":view.page_up", {.Global})
    input.bind_line(&b, "PGDN", {.Shift}, ":view.page_down", {.Global})

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

// A motion and its shift twin, which runs the same verb `extend`ing so the move sweeps a selection.
@(private = "file")
bind_motion :: proc(b: ^[dynamic]input.Bind, key: string, mods: input.Mods, verb: string,
                    ctx: input.Bind_Ctxs) {
    input.bind_line(b, key, mods, fmt.tprintf(":%s", verb), ctx)
    input.bind_line(b, key, mods + {.Shift}, fmt.tprintf(":%s extend", verb), ctx)
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
        origin := input.Origin{.Config, strings.clone(origin_name), row.line}
        // Prepended, because bind_scan takes the first match and the defaults are already in: a
        // file row has to be found before the default it is replacing.
        inject_at(&a.binds, 0, input.Bind{chord = chord, prefix = prefix, line = binds_line(row.value),
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

// A bind holds the line as written; `none` is the empty line. Names are looked up when the chord
// is pressed, so a plugin loaded or reloaded later is just there.
NONE :: "none"

binds_line :: proc(value: string) -> string {
    return value == NONE ? "" : strings.clone(value)
}

// The file's spelling of a row's line, so a written row reads back as the same bind.
binds_value :: proc(line: string) -> string {
    return line == "" ? NONE : line
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
    held:  string, // what the chord runs instead, as the file spells it
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
        if !found || b.line == "" {
            continue
        }
        if held := binds_value(b.line); held != r.line {
            append(&out, Bind_Unmet{r.owner, r.chord, held})
        }
    }
    return out[:]
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
    return binds_value(b.line), true
}

// What a WIDER tier runs for the chord, once this tier is known to be free. The row is still
// written; this only names what it will cover.
binds_shadowed :: proc(a: ^App, ctx_name, chord_text: string) -> (string, bool) {
    ctx, kind, ok := binds_ctx(a, ctx_name)
    prefix, chord, parsed := input.chord_pair_parse(chord_text, key_layout_code)
    if !ok || !parsed || kind == 0 && ctx == .Global {
        return "", false // nothing is wider than a global row
    }
    b, found := input.bind_lookup(a.binds[:], chord, ctx, kind, prefix)
    if !found {
        return "", false
    }
    return binds_value(b.line), true
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
    return section, fmt.tprintf("%s = %s", key, binds_value(b.line))
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

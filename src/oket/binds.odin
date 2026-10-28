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
// A section is a kind's name or a group's, and its header may list groups (sections.odin):
// `[files] (surface send)` walks files, then surface, then global, which is how `enter` means
// one thing in a listing and another in the editor. A value is a command line whose `$o_` names
// fill from point, or `none` to unbind.
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
    bind_in(&b, "ESC", {}, ":file.quit", SEC_GLOBAL)
    bind_in(&b, "FK01", {}, ":describe.key", SEC_GLOBAL)

    // Bare arrows move point in a SURFACE as well as in text: a listing's up and down is the
    // same point move, and nothing else claims an unmodified arrow there. Ctrl and Alt arrows
    // stay narrower, which is what leaves the terminal its own.
    //
    // Letter chords are POSITIONS (QWERTY letters name them below); a layout swap keeps them
    // under the same fingers.
    bind_motion(&b, "UP", {}, "nav.up", SEC_TEXT, SEC_SURFACE)
    bind_motion(&b, "DOWN", {}, "nav.down", SEC_TEXT, SEC_SURFACE)
    bind_motion(&b, "LEFT", {}, "nav.left", SEC_TEXT, SEC_SURFACE)
    bind_motion(&b, "RGHT", {}, "nav.right", SEC_TEXT, SEC_SURFACE)
    bind_motion(&b, "LEFT", {.Ctrl}, "edit.word_left", SEC_TEXT)
    bind_motion(&b, "RGHT", {.Ctrl}, "edit.word_right", SEC_TEXT)
    bind_motion(&b, "HOME", {}, "edit.home", SEC_TEXT)
    bind_motion(&b, "END", {}, "edit.end", SEC_TEXT)
    bind_motion(&b, "HOME", {.Ctrl}, "edit.doc_start", SEC_TEXT)
    bind_motion(&b, "END", {.Ctrl}, "edit.doc_end", SEC_TEXT)
    bind_motion(&b, "UP", {.Ctrl}, "edit.para_up", SEC_TEXT)
    bind_motion(&b, "DOWN", {.Ctrl}, "edit.para_down", SEC_TEXT)
    bind_in(&b, "BKSP", {}, ":edit.delete_back", SEC_TEXT)
    bind_in(&b, "BKSP", {.Shift}, ":edit.delete_back", SEC_TEXT) // shift still down from a capital
    bind_in(&b, "DELE", {}, ":edit.delete_forward", SEC_TEXT)
    bind_in(&b, "BKSP", {.Ctrl}, ":edit.delete_word_back", SEC_TEXT)
    bind_in(&b, "DELE", {.Ctrl}, ":edit.delete_word_forward", SEC_TEXT)
    bind_in(&b, "RTRN", {}, ":edit.newline", SEC_TEXT)
    bind_in(&b, "RTRN", {.Shift}, ":edit.newline", SEC_TEXT)
    bind_in(&b, "KPEN", {}, ":edit.newline", SEC_TEXT)
    bind_in(&b, "TAB", {}, ":edit.tab", SEC_TEXT)
    // The placement verbs (VIEWS.md §4). A caret is PLACED, not walked to, which is why there is
    // no prefix key and no armed mode here: each row says where the next caret goes, and the
    // arrows above already move the whole set. `cursor.split_lines` keeps no default chord and
    // `cursor.collapse` needs none — Escape answers it ahead of every row that claims the key,
    // for exactly as long as a trail is up.
    bind_in(&b, "DOWN", {.Ctrl, .Alt}, ":cursor.add_below", SEC_TEXT, SEC_SURFACE)
    bind_in(&b, "UP", {.Ctrl, .Alt}, ":cursor.add_above", SEC_TEXT, SEC_SURFACE)
    bind_in(&b, "AC03", {.Alt}, ":cursor.add_next_match", SEC_TEXT, SEC_SURFACE) // alt+d
    bind_in(&b, "AC03", {.Alt, .Shift}, ":cursor.add_all_matches", SEC_TEXT, SEC_SURFACE)
    // The mouse row costs nothing, because a button is already a chord (§8).
    bind_in(&b, "click", {.Alt}, ":cursor.add", SEC_TEXT, SEC_SURFACE)

    // ctrl+a and ctrl+e are the most deployed pair there is: every readline prompt and every
    // Cocoa text field. Arrows already carry motion, so the only cost is select-all, which
    // stays a verb with no default chord (Emacs gives it none either).
    bind_motion(&b, "AC01", {.Ctrl}, "edit.home", SEC_TEXT) // ctrl+a
    bind_motion(&b, "AD03", {.Ctrl}, "edit.end", SEC_TEXT) // ctrl+e
    bind_in(&b, "AC02", {.Ctrl}, ":file.dump", SEC_TEXT, SEC_SURFACE) // ctrl+s
    bind_in(&b, "AB01", {.Ctrl}, ":edit.undo", SEC_TEXT, SEC_SURFACE) // ctrl+z
    bind_in(&b, "AB01", {.Ctrl, .Shift}, ":edit.redo", SEC_TEXT, SEC_SURFACE) // a different verb, so Shift is written out
    bind_in(&b, "FK03", {}, ":search.next", SEC_TEXT, SEC_SURFACE)
    bind_in(&b, "FK03", {.Shift}, ":search.prev", SEC_TEXT, SEC_SURFACE)

    // The modern spelling, not Emacs's C-w/M-w/C-y: C-w is the close-window reflex everywhere
    // else. The kill RING is Emacs's — ctrl+shift+v walks it, yank-pop under a guessable name.
    // Text and surface and never global, so a terminal answers for its own: ctrl+c there
    // is `term.copy` and the interrupt is ctrl+shift+c (see the terminal rows below).
    bind_in(&b, "AB02", {.Ctrl}, ":edit.cut", SEC_TEXT, SEC_SURFACE) // ctrl+x
    bind_in(&b, "AB03", {.Ctrl}, ":edit.copy", SEC_TEXT, SEC_SURFACE) // ctrl+c
    bind_in(&b, "AB04", {.Ctrl}, ":edit.paste", SEC_TEXT, SEC_SURFACE) // ctrl+v
    bind_in(&b, "AB04", {.Ctrl, .Shift}, ":edit.paste_cycle", SEC_TEXT, SEC_SURFACE)
    bind_in(&b, "AC08", {.Ctrl}, ":edit.kill_line", SEC_TEXT, SEC_SURFACE) // ctrl+k
    bind_in(&b, "AC08", {.Ctrl, .Shift}, ":edit.kill_whole_line", SEC_TEXT, SEC_SURFACE)
    bind_in(&b, "AD07", {.Ctrl}, ":edit.kill_to_line_start", SEC_TEXT, SEC_SURFACE) // ctrl+u, readline's unix-line-discard

    for n in 1 ..= 9 {
        bind_in(&b, fmt.tprintf("AE%02d", n), {.Alt}, fmt.tprintf(":ring.goto %d", n), SEC_GLOBAL)
    }
    bind_in(&b, "TLDE", {.Alt}, ":ring.alt", SEC_GLOBAL) // alt+` sits at the number row's door
    bind_in(&b, "TLDE", {.Alt, .Shift}, ":ring.alt_lane", SEC_GLOBAL) // and Shift keeps it in one ring
    bind_in(&b, "AD01", {.Alt}, ":ring.close", SEC_GLOBAL) // alt+q
    bind_in(&b, "AE10", {.Alt}, ":ring.zero", SEC_GLOBAL) // alt+0: at the rotation's edge, not in it (§11)
    // The strip (PANELS.md §3, §5). Alt keeps meaning "move between things": the numbers walk
    // the ring, and the side arrows walk the panels. Ctrl on the same two walks the JUMP ring,
    // which is the third thing you move between; their vertical twins are already the placement
    // verbs above, so the whole ctrl+alt cross reads as one family.
    bind_in(&b, "LEFT", {.Alt}, ":panel.prev", SEC_GLOBAL)
    bind_in(&b, "RGHT", {.Alt}, ":panel.next", SEC_GLOBAL)
    // Shift on the walk MOVES what you are looking at, which is the pairing every strip and
    // tab bar already uses.
    bind_in(&b, "LEFT", {.Alt, .Shift}, ":panel.move_left", SEC_GLOBAL)
    bind_in(&b, "RGHT", {.Alt, .Shift}, ":panel.move_right", SEC_GLOBAL)
    bind_in(&b, "LEFT", {.Ctrl, .Alt}, ":jump.back", SEC_GLOBAL)
    bind_in(&b, "RGHT", {.Ctrl, .Alt}, ":jump.forward", SEC_GLOBAL)
    bind_in(&b, "AD10", {.Alt}, ":panel.open", SEC_GLOBAL) // alt+p
    bind_in(&b, "AD10", {.Alt, .Shift}, ":panel.close", SEC_GLOBAL) // the panel, never the document in it
    // alt+w, for width. A LINE, because the sizing model is the row and not the kernel: rebind
    // the list and the same key is a toggle, a three-way or a set.
    bind_in(&b, "AD02", {.Alt}, ":width 33 50 66 100", SEC_GLOBAL)
    bind_in(&b, "AC09", {.Alt}, ":lock", SEC_GLOBAL) // alt+l
    // The universal spelling, and it moves the TEXT rather than the grid: ctrl+= is bigger
    // glyphs, which is fewer cells.
    bind_in(&b, "AE12", {.Ctrl}, ":font.bigger", SEC_GLOBAL) // ctrl+=
    bind_in(&b, "AE11", {.Ctrl}, ":font.smaller", SEC_GLOBAL) // ctrl+-
    bind_in(&b, "AE10", {.Ctrl}, ":font.reset", SEC_GLOBAL) // ctrl+0
    bind_in(&b, "AB03", {.Alt}, ":cl.open", SEC_GLOBAL) // alt+c
    bind_in(&b, "AC10", {.Alt}, ":cl.sigil", SEC_GLOBAL) // alt+;
    // alt+space; under a primer the same key carries THAT primer's modifier (MENU.md §5).
    bind_in(&b, input.PREFIX_HELP, {.Alt}, ":menu.open", SEC_GLOBAL)

    // Switching lanes is its own key, not a walk through the numbers (§5). These are LINES, so
    // the kind is named in a command line the user can read and rebind, and never in a case in
    // the dispatch — which is the whole reason `:ring` exists as a builtin.
    bind_in(&b, "AD03", {.Alt}, ":ring edit", SEC_GLOBAL) // alt+e
    bind_in(&b, "AC04", {.Alt}, ":ring files", SEC_GLOBAL) // alt+f
    bind_in(&b, "AD05", {.Alt}, ":ring term", SEC_GLOBAL) // alt+t
    // alt+. — the lane switch for every OTHER kind, which is a plugin's and so has no letter of
    // its own here. Staged rather than run: the line is `:ring` with the name left to type, and a
    // bare `:ring` lists the lanes.
    bind_in(&b, "AB09", {.Alt}, ":stage :ring", SEC_GLOBAL)
    // A listing's rows are paths, and `enter` is what opens one. Written in the SURFACE group
    // rather than for one kind: a surface whose lines carry no `path` reports that it cannot
    // fill `$o_path`, which is data rather than a refusal decided per call (§8).
    bind_in(&b, "RTRN", {}, ":open $o_path", SEC_SURFACE)
    // The same open, one panel over. §6: the direction preference is a ROW and not a config
    // key, because a row is greppable, rebindable and describable.
    bind_in(&b, "RTRN", {.Ctrl}, ":open $o_path @-1", SEC_SURFACE)

    // The mouse, as ordinary rows (§8). A button chord has none: the kernel moves point before
    // it dispatches one, so `click` with nothing bound already does the thing a click does, and
    // a row is what a surface adds to make it do more.
    bind_in(&b, "double-click", {}, ":select.expand", SEC_TEXT, SEC_SURFACE)
    bind_in(&b, "wheel-up", {}, ":view.scroll_up", SEC_GLOBAL)
    bind_in(&b, "wheel-down", {}, ":view.scroll_down", SEC_GLOBAL)

    // Surface claims: narrower, so they shadow the global rows above (Esc must reach vim inside
    // the shell, never quit oket).
    bind_in(&b, "ESC", {}, ":surface.send", SEC_TERM, SEC_SURFACE)
    // ctrl+c and ctrl+v copy and paste HERE TOO, so one chord means one thing in every document,
    // and ctrl+shift+v pastes as every other terminal's does. The interrupt is
    // ctrl+shift+c: it sends the 0x03 a shell reads as SIGINT, narrowed to the terminal so no
    // other surface claims the chord. Both are ordinary rows, so a binds.conf that swaps them
    // back is two lines.
    bind_in(&b, "AB03", {.Ctrl}, ":term.copy", SEC_TERM) // ctrl+c
    bind_in(&b, "AB03", {.Ctrl, .Shift}, ":surface.send", SEC_TERM)
    bind_in(&b, "AB04", {.Ctrl}, ":term.paste", SEC_TERM) // ctrl+v
    bind_in(&b, "AB04", {.Ctrl, .Shift}, ":term.paste", SEC_TERM)
    // Scrolling a session is the KERNEL's viewport over its document (§11), so these are the
    // same two verbs every other document has and there is no terminal scroll code to bind to.
    bind_in(&b, "PGUP", {.Shift}, ":view.page_up", SEC_GLOBAL)
    bind_in(&b, "PGDN", {.Shift}, ":view.page_down", SEC_GLOBAL)

    // A home-page row is an offer, and `enter` is what takes it: the work a crash left, the
    // plugin that is held back, the file to open. Each row carries the line it runs as `act`, so
    // one row covers every section (home.odin). Narrower than the surface row it shadows, which would
    // open a recovered file and leave the journal sitting beside it (§13).
    bind_in(&b, "RTRN", {}, ":do $o_act", SEC_HOME)
    // A session's links (term_links.odin). Off a link :openlink selects the word, which is what
    // a double-click did before.
    bind_in(&b, "RTRN", {.Alt}, ":openlink", SEC_TERM)
    bind_in(&b, "double-click", {}, ":openlink", SEC_TERM)
    return b
}

// A motion and its shift twin, which runs the same verb `extend`ing so the move sweeps a selection.
@(private = "file")
bind_motion :: proc(b: ^[dynamic]input.Bind, key: string, mods: input.Mods, verb: string,
                    sections: ..Section) {
    bind_in(b, key, mods, fmt.tprintf(":%s", verb), ..sections)
    bind_in(b, key, mods + {.Shift}, fmt.tprintf(":%s extend", verb), ..sections)
}

// One row per section, in the order given.
@(private = "file")
bind_in :: proc(b: ^[dynamic]input.Bind, key: string, mods: input.Mods, line: string,
                sections: ..Section) {
    for s in sections {
        input.bind_line(b, key, mods, line, s)
    }
}

// Defaults first, the file over them. Called again whenever the set of surface kinds changes,
// because a section may name one.
binds_load :: proc(a: ^App, path: string) {
    input.binds_destroy(&a.binds)
    a.binds = binds_base()
    groups_clear(a)
    raw, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return
    }
    binds_parse(a, string(raw), BINDS_NAME)
}

// Split from binds_load so the parse is testable without a filesystem. A bad row is reported and
// skipped; one typo does not cost the file.
binds_parse :: proc(a: ^App, text, origin_name: string) {
    conf_forget(a, origin_name) // a re-read replaces what the last one found
    binds_groups(a, text, origin_name)
    rows, errs := conf.parse(text)
    for e in errs {
        conf_complain(a, origin_name, e.line, e.why)
    }
    for row in rows {
        section := row.section == "" ? SEC_GLOBAL : section_intern(a, row.section)
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
                                          section = section, origin = origin})
    }
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
        prefix, chord, parsed := input.chord_pair_parse(r.chord, key_layout_code)
        if !parsed {
            continue
        }
        // bind_at, not bind_lookup: a wider row still leaves this section free, and the
        // writeback writes the narrow row live.
        b, found := input.bind_at(a.binds[:], chord, section_intern(a, r.ctx), prefix)
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

// What a chord runs in THIS section, for the clash note. bind_at, not bind_lookup: a resolving
// lookup reads a wider default as a collision and refuses the narrower row that wins at runtime.
binds_held :: proc(a: ^App, section_name, chord_text: string) -> (string, bool) {
    prefix, chord, parsed := input.chord_pair_parse(chord_text, key_layout_code)
    if !parsed {
        return "", false
    }
    b, found := input.bind_at(a.binds[:], chord, section_intern(a, section_name), prefix)
    if !found {
        return "", false
    }
    return binds_value(b.line), true
}

// What a WIDER section runs for the chord, once this one is known to be free. The row is still
// written; this only names what it will cover.
binds_shadowed :: proc(a: ^App, section_name, chord_text: string) -> (string, bool) {
    prefix, chord, parsed := input.chord_pair_parse(chord_text, key_layout_code)
    section := section_intern(a, section_name)
    if !parsed || section == SEC_GLOBAL {
        return "", false // nothing is wider than a global row
    }
    path, _ := section_path(a, section)
    b, found := input.bind_lookup(a.binds[:], chord, path, prefix)
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
    sections := make([dynamic]Section, context.temp_allocator)
    for d in base {
        if !slice.contains(sections[:], d.section) {
            append(&sections, d.section)
        }
    }
    b := strings.builder_make(context.temp_allocator)
    for section, i in sections {
        fmt.sbprintf(&b, "%s%s\n", i > 0 ? "\n" : "", section_header(a, section))
        for d in base {
            if d.section == section {
                fmt.sbprintf(&b, "%s\n", binds_row(d))
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
        if !binds_filed(a.binds[:], d) {
            append(&out, fmt.aprintf("[%s] %s", section_name(a, d.section), binds_row(d),
                                     allocator = allocator))
        }
    }
    return out[:]
}

@(private = "file")
binds_filed :: proc(binds: []input.Bind, d: input.Bind) -> bool {
    for b in binds {
        if b.origin.src == .Config && b.section == d.section && b.chord == d.chord &&
           b.prefix == d.prefix {
            return true
        }
    }
    return false
}

@(private = "file")
binds_row :: proc(b: input.Bind) -> string {
    key := chord_spelled(b.chord)
    if b.prefix != {} {
        key = fmt.tprintf("%s %s", chord_spelled(b.prefix), key)
    }
    return fmt.tprintf("%s = %s", key, binds_value(b.line))
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

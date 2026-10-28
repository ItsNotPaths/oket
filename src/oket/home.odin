package main

import "lues:lues"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../desc"
import "../input"
import "../store"
import "../txt"
import "../cl"

// The home page (§13): what the kernel has to tell you at a start, as a document rather than as
// a screen. What a crash left behind, the plugins it took with it, how this start came up, the
// chords that are in each other's way, and what changed in the build you are running.
//
// IT IS THE DEFAULT DOCUMENT. A start with no session to restore opens this and not a listing:
// the working directory is one row away on the page, and a listing cannot say any of the above.
//
// A DOCUMENT because it is acted on. `enter` over a row runs the line the row carries as `act`,
// and that is one `binds.conf` row over one field — the same shape a listing's `enter`
// has, so recovery needs no key job, no dialog and no mode. screen.odin stays what it was: the
// floor with nothing focused, which is a different question.
//
// IT IS THE KERNEL'S AND NOT A PLUGIN'S, which is the one place §7's rule bends and it bends
// for a reason: the page reports quarantined plugins and `--no-plugins`, so a plugin drawing it
// would be missing at exactly the start that needs it. Everything it lists is a kernel table
// with no seam to read it through.

// In the data directory, like plugins/ and themes/. Written by the release rather than by
// oket: notes are what shipped, so nothing at runtime has an opinion about them.
NOTES_NAME :: "notes.md"

NOTES_BAKED :: string(#load("../../notes.md"))

// How many lines of the newest section the page shows before it stops and offers the file.
NOTES_LINES :: 8

home_open :: proc(a: ^App) -> store.Id {
    id := store.store_open(a.docs)
    home_fill(a, id)
    return id
}

// Every open home page, rewritten. What it lists is the state of two directories and a bind
// table, so a recover, a `:plug load` or an edit to binds.conf has to be visible without
// closing the page that offered it.
home_refresh :: proc(a: ^App) {
    for id in store.store_ids(a.docs) {
        if doc_kind(a, id) == KIND_HOME {
            home_fill(a, id)
        }
    }
}

// Whether the page has anything past its header. The page opens either way; this is for the
// start that restored a session instead, where the news would otherwise never be seen.
home_news :: proc(a: ^App) -> bool {
    return len(recover_scan(a)) > 0 ||
           len(a.kernel.quarantined) > 0 ||
           len(binds_unmet(a, context.temp_allocator)) > 0 ||
           len(binds_missing(a)) > 0 ||
           len(config_missing(a)) > 0 ||
           len(a.gripes) > 0 ||
           len(plugins_held(a.home.data)) > 0
}

// The page as it is being written: the bytes, the data spans named in them, and how many lines
// are down. One struct rather than four pointers threaded through every call.
@(private = "file")
Page :: struct {
    a:     ^App,
    text:  strings.Builder,
    spans: [dynamic]store.Span,
    line:  int,
}

@(private = "file")
say :: proc(p: ^Page, s: string) {
    if p.line > 0 {
        strings.write_rune(&p.text, '\n')
    }
    strings.write_string(&p.text, s)
    p.line += 1
}

// A heading, with the blank line that separates it from what came before.
@(private = "file")
head :: proc(p: ^Page, s: string) {
    say(p, "")
    say(p, s)
}

// An offer: two spaces, the value it acts on, then whatever else the line says. The value is an
// `act` span over the line's own bytes whose VALUE is the line `enter` runs (`[home] enter =
// :do $o_act`), so hover underlines exactly what `enter` would take.
@(private = "file")
offer :: proc(p: ^Page, value, tail, act: string) {
    at := strings.builder_len(p.text) + (p.line > 0 ? 1 : 0) + 2
    say(p, fmt.tprintf("  %s%s", value, tail))
    append(&p.spans, store.Span{lo = at, hi = at + len(value), key = store.Key(token_intern(p.a, "act")),
                                open = true, text = act, valued = true})
}

@(private = "file")
open_line :: proc(path: string) -> string {
    return fmt.tprintf(":open %s", cl.sh_arg(path))
}

@(private = "file")
home_fill :: proc(a: ^App, id: store.Id) {
    p := Page {
        a     = a,
        text  = strings.builder_make(context.temp_allocator),
        spans = make([dynamic]store.Span, context.temp_allocator),
    }
    say(&p, fmt.tprintf("oket %s", version_text()))
    // The mode, only when it is not the ordinary one. A start that held every plugin back looks
    // from the inside exactly like a start whose plugins are all broken (§13).
    switch a.start {
    case .Safe:
        say(&p, "safe mode: no plugin was loaded, and the last session was ignored")
    case .No_Plugins:
        say(&p, "--no-plugins: nothing under plugins/ was loaded")
    case .Ordinary:
    }
    // Nothing here can be saved, and the page is where a start says so. `:oket` is spelled out
    // rather than made a field, because the fix is a command and not a path to act on.
    if a.home.config != "" && !home_writable(a.home.config) {
        say(&p, fmt.tprintf("%s cannot be written, so no setting is saved (:oket install)",
                            a.home.config))
    }

    if work := recover_scan(a); len(work) > 0 {
        head(&p, "unsaved work a crash left behind — enter takes it back:")
        for r in work {
            offer(&p, r.path, fmt.tprintf("   %d edit(s)", r.edits), fmt.tprintf(":recover %s", cl.sh_arg(r.path)))
        }
        say(&p, "  (:recover drop <path> throws one away)")
    }

    if len(a.kernel.quarantined) > 0 {
        head(&p, "plugins that took a start down, and are not loaded:")
        for name in a.kernel.quarantined {
            offer(&p, name, "", fmt.tprintf(":plug load %s", cl.sh_arg(name)))
        }
        say(&p, "  (:plug load <name> takes one again, once it is fixed)")
    }

    if held := plugins_held(a.home.data); len(held) > 0 {
        head(&p, "plugins you edited, which the last update left as they were:")
        for name in held {
            dir, _ := filepath.join({a.home.data, PLUGIN_DIR, name}, context.temp_allocator)
            offer(&p, dir, "   the release had a different one", open_line(dir))
        }
        say(&p, "  (delete the folder and :oket update to take the release's)")
    }

    home_binds(a, &p)
    home_notes(a, &p)

    // Where oket thinks it is, as a row rather than as the start's document. `:open` on it is
    // the browser's, so a start with no browser reports that instead of drawing an empty page.
    if a.dir != "" {
        say(&p, "")
        offer(&p, a.dir, "   the directory this start is in", open_line(a.dir))
    }
    say(&p, "alt+space the menu   alt+f files   alt+t term   " +
             "alt+c command line   f1 describes a chord")

    doc := store.store_doc(a.docs, id)
    if doc == nil {
        return
    }
    gen := doc.gen
    d := desc.new_from(
        {
            kind = KIND_HOME,
            selection = .Line,
            tab_width = 4,
        },
    )
    text := strings.to_string(p.text)
    whole := txt.Edit{0, txt.doc_len(doc), text, 0, 0}
    store.store_submit(a.docs, id, gen, {whole}, d,
                       store.Spans{who = producer_intern(a, "home"), hi = len(text), list = p.spans[:]})
    desc.release(d)
    lues.kernel_settle(a.kernel)
}

// The ways a chord or a row goes wrong, and each is a different fix, so each is its own list.
@(private = "file")
home_binds :: proc(a: ^App, p: ^Page) {
    path := binds_path(a)

    // A chord that is both a primer and a row of its own. Neither wins on merit — the scan
    // takes whichever it reaches — so the file is asked to decide rather than the kernel (§4).
    clashes := input.bind_collisions(a.binds[:], key_layout_name, names(a), context.temp_allocator)
    if len(clashes) > 0 {
        head(p, "chords that are a primer AND a row; one of the two never fires:")
        for c in clashes {
            offer(p, c.chord, fmt.tprintf("   runs %s, and %d row(s) hide behind it", c.runs, c.kids),
                  open_line(path))
        }
        say(p, fmt.tprintf("  (move one of them in %s)", BINDS_NAME))
    }

    if unmet := binds_unmet(a, context.temp_allocator); len(unmet) > 0 {
        head(p, fmt.tprintf("chords a plugin asked for that %s answers itself:", BINDS_NAME))
        for u in unmet {
            offer(p, u.chord, fmt.tprintf("   %s asked for it; it runs %s", u.owner, u.held),
                  open_line(path))
        }
        say(p, "  (the plugin's own row is in the file, commented out, under its name)")
    }

    home_missing(p, BINDS_NAME, path, binds_missing(a))
    home_missing(p, CONFIG_NAME, config_path(a), config_missing(a))

    if len(a.gripes) > 0 {
        head(p, "lines the config could not be read as anything:")
        for g in a.gripes {
            // The span is where the line is; what the row opens is the file beside it.
            at, _ := filepath.join({a.home.config, g.file}, context.temp_allocator)
            offer(p, fmt.tprintf("%s:%d", g.file, g.line), fmt.tprintf("   %s", g.why), open_line(at))
        }
    }
}

@(private = "file")
home_missing :: proc(p: ^Page, name, path: string, rows: []string) {
    if len(rows) == 0 {
        return
    }
    head(p, fmt.tprintf("rows %s lacks; the built-in default runs:", name))
    for r in rows {
        offer(p, r, "", open_line(path))
    }
    say(p, fmt.tprintf("  (write the row back; in %s, `= none` unbinds a chord)", BINDS_NAME))
}

// What changed in the build you are running, off notes.md in the data directory. The newest section
// and no more: the page is a start's report and not a changelog, and the file is one row away.
// File first, baked fallback: a dropped data/notes.md still wins, but the binary carries what
// shipped.
@(private = "file")
home_notes :: proc(a: ^App, p: ^Page) {
    if a.home.data == "" {
        return
    }
    path, _ := filepath.join({a.home.data, NOTES_NAME}, context.temp_allocator)
    text: string
    has_file := false
    if raw, err := os.read_entire_file(path, context.temp_allocator); err == nil {
        text = string(raw)
        has_file = true
    } else if len(NOTES_BAKED) != 0 {
        path = fmt.tprintf("baked %s", NOTES_NAME)
        text = NOTES_BAKED
    } else {
        return
    }
    title, body, found := notes_head(text)
    if !found {
        return
    }
    head(p, fmt.tprintf("new in this build — %s:", title))
    for line in body[:min(len(body), NOTES_LINES)] {
        say(p, fmt.tprintf("  %s", line))
    }
    if has_file {
        offer(p, path, "   the rest of them", open_line(path))
    } else {
        offer(p, path, "   in the binary", open_line(path))
    }
}

// The first `## <title>` in the file and the lines under it, blank ones at either end dropped.
// A markdown heading, because the file is read by people far more often than by this.
@(private = "file")
notes_head :: proc(text: string) -> (title: string, body: []string, ok: bool) {
    lines := make([dynamic]string, context.temp_allocator)
    rest := text
    for line in strings.split_lines_iterator(&rest) {
        trimmed := strings.trim_right_space(line)
        if strings.has_prefix(trimmed, "## ") {
            if title != "" {
                break // the section under it is the one before this build's
            }
            title = strings.trim_space(trimmed[3:])
            continue
        }
        if title == "" {
            continue // a preamble, or a `# ` the file opens with
        }
        if trimmed == "" && len(lines) == 0 {
            continue
        }
        append(&lines, trimmed)
    }
    for len(lines) > 0 && lines[len(lines) - 1] == "" {
        pop(&lines)
    }
    return title, lines[:], title != ""
}

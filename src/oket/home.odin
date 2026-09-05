package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../desc"
import "../input"
import "../store"
import "../txt"

// The home page (§13): what the kernel has to tell you at a start, as a document rather than as
// a screen. What a crash left behind, the plugins it took with it, how this start came up, the
// chords that are in each other's way, and what changed in the build you are running.
//
// IT IS THE DEFAULT DOCUMENT. A start with no session to restore opens this and not a listing:
// the working directory is one row away on the page, and a listing cannot say any of the above.
//
// A DOCUMENT because it is acted on. `enter` over a row runs the verb the row's own field asks
// for, and that is one `binds.conf` row over one lookup — the same shape a listing's `enter`
// has, so recovery needs no key job, no dialog and no mode. screen.odin stays what it was: the
// floor with nothing focused, which is a different question.
//
// IT IS THE KERNEL'S AND NOT A PLUGIN'S, which is the one place §7's rule bends and it bends
// for a reason: the page reports quarantined plugins and `--no-plugins`, so a plugin drawing it
// would be missing at exactly the start that needs it. Everything it lists is a kernel table
// with no seam to read it through.

// Beside the binary, like binds.conf. Written by the release rather than by oket: notes are
// what shipped, so nothing at runtime has an opinion about them.
NOTES_NAME :: "notes.md"

// How many lines of the newest section the page shows before it stops and offers the file.
NOTES_LINES :: 8

home_open :: proc(a: ^App) -> store.Id {
    id := store.store_open(&a.docs)
    home_fill(a, id)
    return id
}

// Every open home page, rewritten. What it lists is the state of two directories and a bind
// table, so a recover, a `:plug load` or an edit to binds.conf has to be visible without
// closing the page that offered it.
home_refresh :: proc(a: ^App) {
    for id in store.store_ids(&a.docs) {
        if doc_kind(a, id) == KIND_HOME {
            home_fill(a, id)
        }
    }
}

// Whether the page has anything past its header. The page opens either way; this is for the
// start that restored a session instead, where the news would otherwise never be seen.
home_news :: proc(a: ^App) -> bool {
    return len(recover_scan(a)) > 0 ||
           len(a.quarantined) > 0 ||
           len(binds_unmet(a, context.temp_allocator)) > 0 ||
           len(a.gripes) > 0
}

// `enter` over a row, as the verb the row's own field asks for. The lines are the ones you
// could have typed, and the order is the page's own: work a crash left, then a plugin held
// back, then a file to open. A row carrying none of them is prose, and says so.
// Not file-private: the link renderer reads the same table (routing.odin), so what is drawn as
// an offer and what `enter` takes cannot come apart.
@(rodata)
HOME_VERBS := [?]struct {
    field: string,
    line:  string,
} {
    {"path", ":recover <path>"},
    {"plug", ":plug load <plug>"},
    {"file", ":open <file>"},
}

home_enter :: proc(a: ^App) -> bool {
    s := active(a)
    d := s != nil ? store.store_descriptor(&a.docs, s.doc) : nil
    if d == nil {
        message_set(a, ":home enter: nothing is focused")
        return false
    }
    defer desc.release(d)
    for v in HOME_VERBS {
        if _, carried := desc.field_of(d, s.view.point.head.line, v.field); !carried {
            continue
        }
        // bind_expand, so a hole fills here exactly the way it fills for a chord, and the
        // value a field carries is what runs rather than the bytes it drew.
        line, filled := bind_expand(a, v.line)
        if !filled {
            return false
        }
        cl_exec(a, line)
        return true
    }
    message_set(a, ":home enter: this row is not an offer")
    return false
}

// The page as it is being written: the bytes, the spans named in them, and how many lines are
// down. One struct rather than three pointers threaded through every call.
@(private = "file")
Page :: struct {
    text:   strings.Builder,
    fields: [dynamic]desc.Field,
    line:   int,
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

// A row: two spaces, the value a bind acts on, then whatever else the line says. The value is a
// span of the line's own bytes, so hover underlines exactly what `enter` would take.
@(private = "file")
row :: proc(p: ^Page, name, value, tail: string) {
    at := 2
    say(p, fmt.tprintf("  %s%s", value, tail))
    append(&p.fields, desc.Field{p.line - 1, name, at, at + len(value), ""})
}

// A second name over the row already written, whose VALUE is not the span it covers. What makes
// a chord row a link: the line draws the chord, and `<file>` hands on binds.conf.
@(private = "file")
also :: proc(p: ^Page, name, value: string) {
    last := p.fields[len(p.fields) - 1]
    append(&p.fields, desc.Field{last.line, name, last.lo, last.hi, value})
}

@(private = "file")
home_fill :: proc(a: ^App, id: store.Id) {
    p := Page {
        text   = strings.builder_make(context.temp_allocator),
        fields = make([dynamic]desc.Field, context.temp_allocator),
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

    if work := recover_scan(a); len(work) > 0 {
        head(&p, "unsaved work a crash left behind — enter takes it back:")
        for r in work {
            row(&p, "path", r.path, fmt.tprintf("   %d edit(s)", r.edits))
        }
        say(&p, "  (:recover drop <path> throws one away)")
    }

    // `plug` is named for the same reason `size` is named in a tree the browser never draws it
    // in: no kernel row reads it, and a `[home] delete = exec :plug load <plug>` in binds.conf
    // would, without this file learning a second verb.
    if len(a.quarantined) > 0 {
        head(&p, "plugins that took a start down, and are not loaded:")
        for name in a.quarantined {
            row(&p, "plug", name, "")
        }
        say(&p, "  (:plug load <name> takes one again, once it is fixed)")
    }

    home_binds(a, &p)
    home_notes(a, &p)

    // The working directory as a row rather than as the start's document. `:open` on it is the
    // browser's, so a start with no browser reports that instead of drawing an empty page.
    if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
        say(&p, "")
        row(&p, "file", cwd, "   the directory you started in")
    }
    say(&p, "alt+space the menu   alt+f files   alt+t term   " +
             "alt+c command line   f1 describes a chord")

    doc := store.store_doc(&a.docs, id)
    if doc == nil {
        return
    }
    gen := doc.gen
    d := desc.new_from(
        {
            ctx = kind_ctx(a, KIND_HOME),
            kind = KIND_HOME,
            selection = .Line,
            tab_width = 4,
            fields = p.fields[:],
        },
    )
    whole := txt.Edit{0, txt.doc_len(doc), strings.to_string(p.text), 0, 0}
    store.store_submit(&a.docs, id, gen, {whole}, d)
    desc.release(d)
    store.store_drain(&a.docs)
}

// The three ways a chord goes wrong, and each is a different fix, so each is its own list.
@(private = "file")
home_binds :: proc(a: ^App, p: ^Page) {
    path := binds_path(a)

    // A chord that is both a primer and a row of its own. Neither wins on merit — the scan
    // takes whichever it reaches — so the file is asked to decide rather than the kernel (§4).
    clashes := input.bind_collisions(a.binds[:], key_layout_name, names(a), context.temp_allocator)
    if len(clashes) > 0 {
        head(p, "chords that are a primer AND a row; one of the two never fires:")
        for c in clashes {
            row(p, "chord", c.chord, fmt.tprintf("   runs %s, and %d row(s) hide behind it",
                                                 c.runs, c.kids))
            also(p, "file", path)
        }
        say(p, fmt.tprintf("  (move one of them in %s)", BINDS_NAME))
    }

    if unmet := binds_unmet(a, context.temp_allocator); len(unmet) > 0 {
        head(p, fmt.tprintf("chords a plugin asked for that %s answers itself:", BINDS_NAME))
        for u in unmet {
            row(p, "chord", u.chord, fmt.tprintf("   %s asked for it; it runs %s", u.owner,
                                                 u.held))
            also(p, "file", path)
        }
        say(p, "  (the plugin's own row is in the file, commented out, under its name)")
    }

    if len(a.gripes) > 0 {
        head(p, "lines the config could not be read as anything:")
        for g in a.gripes {
            // `at`, not `chord`: the span is where the line is, and what a row acts on is the
            // file beside it.
            row(p, "at", fmt.tprintf("%s:%d", g.file, g.line), fmt.tprintf("   %s", g.why))
            at, _ := filepath.join({a.home, g.file}, context.temp_allocator)
            also(p, "file", at)
        }
    }
}

// What changed in the build you are running, off notes.md beside the binary. The newest section
// and no more: the page is a start's report and not a changelog, and the file is one row away.
@(private = "file")
home_notes :: proc(a: ^App, p: ^Page) {
    if a.home == "" {
        return
    }
    path, _ := filepath.join({a.home, NOTES_NAME}, context.temp_allocator)
    raw, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return
    }
    title, body, found := notes_head(string(raw))
    if !found {
        return
    }
    head(p, fmt.tprintf("new in this build — %s:", title))
    for line in body[:min(len(body), NOTES_LINES)] {
        say(p, fmt.tprintf("  %s", line))
    }
    row(p, "file", path, "   the rest of them")
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

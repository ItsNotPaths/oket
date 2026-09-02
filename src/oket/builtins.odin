package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../desc"
import "../store"
import "../txt"

// The kernel's curated core set (§12). Everything past it arrives with plugins, and the sigil
// promised a builtin, so an unknown name stops the chain and says so rather than falling
// through to the shell — a `:` that silently ran something else would be the worst of both.

cl_builtin :: proc(a: ^App, step: CL_Step) -> bool {
    name := first_field(step.text)
    args := strings.trim_space(step.text[len(name):])
    switch name {
    case "open":
        return builtin_open(a, args)
    case "ring":
        return builtin_ring(a, args)
    case "ls":
        return builtin_ls(a)
    case "sel":
        return builtin_sel(a)
    case "put":
        return builtin_put(a, step)
    case "close":
        // ring.close as a command line. alt+q already does exactly this, and a plugin that
        // opened a document will have no other way to end it (stage 7).
        if ring_focused(&a.ring) == nil {
            message_set(a, ":close: nothing is focused")
            return false
        }
        ring_close(a, a.ring.focused)
    case "q":
        a.quit = true
    case:
        message_set(a, fmt.tprintf("%s: not a builtin (drop the : to run it in the shell)", name))
        return false
    }
    return true
}

// `:open <path> [slot]`. The slot is an ARGUMENT, which is what makes the routing target
// typed, visible and editable before it commits (§5): `stage :open <path>` puts the line in the
// command line and you aim it there. No routing hook, no display-buffer-alist.
@(private = "file")
builtin_open :: proc(a: ^App, args: string) -> bool {
    raw, path := first_arg(args)
    rest := strings.trim_space(args[len(raw):])
    if path == "" {
        message_set(a, ":open <path> [slot]")
        return false
    }
    slot := 0
    if rest != "" {
        n, ok := strconv.parse_int(rest, 10)
        if !ok || n < 1 {
            message_set(a, ":open: the slot is a number from 1 up")
            return false
        }
        slot = n
    }
    id, ok := open_path(a, path)
    if !ok {
        return false
    }
    if slot == 0 {
        ring_add(a, id)
    } else {
        ring_put(a, id, slot)
    }
    return true
}

// A directory is a listing and a file is text: one kind each, and the descriptor is what makes
// the kernel able to draw either without knowing which it asked for.
@(private = "file")
open_path :: proc(a: ^App, path: string) -> (store.Id, bool) {
    info, err := os.stat(path, context.temp_allocator)
    if err != nil {
        message_set(a, fmt.tprintf(":open: cannot read %s: %v", path, err))
        return {}, false
    }
    if info.type == .Directory {
        return listing_open(&a.docs, path), true
    }
    raw, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        message_set(a, fmt.tprintf(":open: cannot read %s: %v", path, rerr))
        return {}, false
    }
    return text_open(&a.docs, path, string(raw)), true
}

// `:ring <kind>`: go to that kind's lane (§5). What a `[global] alt+e = exec :ring text` row
// runs, and the reason it is a row rather than a case in the dispatch — the kind is named in
// the config and never in kernel source.
@(private = "file")
builtin_ring :: proc(a: ^App, args: string) -> bool {
    _, name := first_arg(args)
    if name == "" {
        for l, i in a.ring.lanes {
            sys_println(a, fmt.tprintf("%s%s", i == a.ring.lane ? "> " : "  ", kind_name(l.kind)))
        }
        ring_show_system(a)
        return true
    }
    lane, found := ring_lane_named(a, name)
    if !found {
        message_set(a, fmt.tprintf(":ring: nothing has registered a kind called %s", name))
        return false
    }
    // A lane with nothing in it still opens: slot 1 of it, which is what makes `:ring text`
    // useful before the first file is open.
    if !ring_lane_enter(a, lane) {
        message_set(a, fmt.tprintf(":ring: %s opened nothing", name))
        return false
    }
    return true
}

// The ring, printed into N#, which surfaces to show it.
@(private = "file")
builtin_ls :: proc(a: ^App) -> bool {
    n := 0
    for l, lane in a.ring.lanes {
        for s, i in l.slots {
            if !s.live {
                continue // a gap keeps its number; it just has nothing in it
            }
            here := lane == a.ring.lane && i + 1 == a.ring.focused
            sys_println(a, fmt.tprintf("%s%s %d %s", here ? "> " : "  ", kind_name(l.kind),
                                       i + 1, doc_title(a, s.doc)))
            n += 1
        }
    }
    if n == 0 {
        sys_println(a, "the ring is empty")
    }
    ring_show_system(a)
    return true
}

// --- the two boundaries a shell cannot see ---

// `:sel` puts the selection on the next step's stdin. With nothing selected it takes the line
// under point and SELECTS it, so what a following `:put` replaces is what you were shown —
// same rule as `edit.copy`, which takes the selection or the line.
@(private = "file")
builtin_sel :: proc(a: ^App) -> bool {
    s := ring_focused(&a.ring)
    if s == nil {
        message_set(a, ":sel: nothing is focused")
        return false
    }
    doc := store.store_doc(&a.docs, s.doc)
    if doc == nil {
        return false
    }
    c := doc.cursors[doc.primary]
    if !txt.cursor_has_selection(c) {
        txt.doc_select_line(doc, c.head.line)
        c = doc.cursors[doc.primary]
    }
    lo, hi := txt.cursor_range(c)
    text := txt.doc_text(doc, lo, hi, context.temp_allocator)
    chain_feed(a, text)
    s.view.point = doc.cursors[doc.primary]
    return true
}

// `:put` takes what was piped into it and replaces the selection with it, at point. Emacs's
// shell-command-on-region, as a chain step: `:sel | sort -u | :put`.
@(private = "file")
builtin_put :: proc(a: ^App, step: CL_Step) -> bool {
    if !step.piped || !a.chain.fed {
        message_set(a, ":put: nothing was piped into it")
        return false
    }
    s := ring_focused(&a.ring)
    if s == nil {
        message_set(a, ":put: nothing is focused")
        return false
    }
    d := store.store_descriptor(&a.docs, s.doc)
    defer desc.release(d)
    if d == nil || !d.editable {
        message_set(a, ":put: this document does not take typing")
        return false
    }
    doc := store.store_doc(&a.docs, s.doc)
    txt.doc_insert_text(doc, a.chain.feed) // one edit per cursor, replacing its range
    s.view.point = doc.cursors[doc.primary]
    return true
}

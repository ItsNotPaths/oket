package main

import "core:fmt"
import "core:strings"
import "../store"
import "../txt"

// Search, and it is nearly all `txt` already: `doc_find` walks a direction and wraps,
// `doc_find_all` collects every hit. What is here is the TERM — one per app, the way every
// editor's last search is — and the two shapes a hit takes.
//
// A hit is a SELECTION, which is why nothing here draws: the renderer already draws selections,
// so `:find` highlights every match by making one caret per match. That also makes replace-all
// a thing you type rather than a verb — N selections take a typed rune as one commit, so
// `:find foo` then typing is find-and-replace with no replace command anywhere.

// The term the two verbs step through. Owned, and the only state search keeps.
find_set :: proc(a: ^App, pattern: string) {
    delete(a.find)
    a.find = pattern == "" ? "" : strings.clone(pattern)
}

find_free :: proc(a: ^App) {
    delete(a.find)
    a.find = ""
}

// The ring-focused document, never the command line's: a search runs over what you are reading.
@(private = "file")
find_doc :: proc(a: ^App) -> ^txt.Doc {
    s := ring_focused(a)
    return s != nil ? store.store_doc(&a.docs, s.doc) : nil
}

// `:find <pattern>` — every match at once, as selections. The primary is the first hit at or
// after point rather than the first in the file, so the screen goes where you were looking.
builtin_find :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    pattern := strings.trim_space(args)
    if pattern == "" {
        message_set(a, USAGE_FIND)
        return false
    }
    doc := find_doc(a)
    if doc == nil {
        message_set(a, ":find: nothing is focused")
        return false
    }
    find_set(a, pattern)
    hits := txt.doc_find_all(doc, pattern)
    if len(hits) == 0 {
        message_set(a, fmt.tprintf(":find: no match for %q", pattern))
        return false
    }
    jump_here(a) // so jump.back returns to where you were reading, not to the first hit
    at := doc.cursors[doc.primary].head
    primary := 0
    for h, i in hits {
        if !txt.pos_less(h[0], at) {
            primary = i
            break
        }
    }
    txt.doc_set_spans(doc, hits, primary)
    point_sync(a)
    message_set(a, fmt.tprintf("%d matches of %q; type to replace them all", len(hits), pattern))
    return true
}

USAGE_FIND :: ":find <text>"

// F3 and shift+F3: one hit at a time, from the primary. The set collapses, because stepping
// through matches and holding them all are two different things to be looking at.
search_step :: proc(a: ^App, dir: txt.Find_Dir) {
    if a.find == "" {
        message_set(a, fmt.tprintf("nothing to search for yet (%s)", USAGE_FIND))
        return
    }
    doc := find_doc(a)
    if doc == nil {
        return
    }
    lo, _ := txt.cursor_range(doc.cursors[doc.primary])
    // Back from the START of the selection: `doc_find` looks strictly past what it is given, so
    // searching back from a hit's own end would land on that same hit again.
    from := dir == .Forward ? doc.cursors[doc.primary].head : lo
    at, found := txt.doc_find(doc, a.find, from, dir)
    if !found {
        message_set(a, fmt.tprintf("no match for %q", a.find))
        return
    }
    jump_here(a)
    // reset, not set_head: set_head moves the PRIMARY and leaves the rest, so stepping out of a
    // `:find` would drag one caret away from a trail that is still up.
    txt.doc_reset_cursor(doc, at)
    txt.doc_set_head(doc, txt.Pos{at.line, at.col + len(a.find)}, true)
    point_sync(a)
}

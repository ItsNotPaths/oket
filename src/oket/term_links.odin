package main

import "core:strings"
import "../pty"
import "../store"

// A session's links, as `link` data runs that go beside its colour in `tm.spans`: what a
// program marked with OSC 8 first, then what the scan finds in plain output, by link_value's
// rules from where the shell stands. A soft-wrapped link is one run across the row break, and its
// value is the text without the break. Every run's text is owned by `tm.spans`.

// Path answers remembered between pumps, so a still screen costs no stats.
TERM_RESOLVED_MAX :: 4096

// The rewrite: document bytes from `lo`, absolute rows from `first`, `starts[k]` where row
// `first + k` begins in the document.
term_links :: proc(a: ^App, tm: ^Term, text: string, lo, first: int, starts: []int,
                   out: ^[dynamic]store.Span) {
    if len(starts) == 0 {
        return
    }
    key := store.Key(token_intern(a, LINK_KEY))
    last := first + len(starts) - 1
    for l in tm.t.links {
        if l.from[0] < first || l.from[0] > last {
            continue // begun above the rewrite, so an earlier pump published it
        }
        from := term_cell_off(tm, l.from, first, lo, text, starts)
        to := term_cell_off(tm, l.to, first, lo, text, starts)
        if to > from {
            append(out, store.Span{lo = from, hi = to, key = key, text = strings.clone(l.uri),
                                   valued = true})
        }
    }
    soft := make(map[int]bool, context.temp_allocator)
    for k in 1 ..< len(starts) {
        if pty.terminal_continuation(&tm.t, first + k) {
            soft[starts[k] - lo - 1] = true
        }
    }
    // A first row that continues the one above starts mid-token, and that token was published
    // with the row it began on.
    skip := pty.terminal_continuation(&tm.t, first)
    cwd := ""
    for i := 0; i < len(text); {
        if term_link_break(text, i, soft) {
            i += 1
            skip = false
            continue
        }
        start := i
        for i < len(text) && !term_link_break(text, i, soft) {
            i += 1
        }
        if skip {
            skip = false
            continue
        }
        tlo, thi := term_link_trim(text, start, i)
        if thi <= tlo || thi - tlo > 4096 {
            continue
        }
        tok, _ := strings.remove_all(text[tlo:thi], "\n", context.temp_allocator)
        if !strings.contains_any(tok, "/.") {
            continue
        }
        if cwd == "" {
            cwd = term_link_cwd(tm)
        }
        if value, ok := term_link_value(tm, tok, cwd); ok {
            append(out, store.Span{lo = lo + tlo, hi = lo + thi, key = key,
                                   text = strings.clone(value), valued = true})
        }
    }
}

// Whitespace, and a newline the terminal did not soft-wrap.
@(private = "file")
term_link_break :: proc(text: string, i: int, soft: map[int]bool) -> bool {
    switch text[i] {
    case ' ', '\t':
        return true
    case '\n':
        return !soft[i]
    }
    return false
}

// Less the punctuation prose wraps around a link, and any soft break at either end.
@(private = "file")
term_link_trim :: proc(text: string, lo, hi: int) -> (int, int) {
    lo, hi := lo, hi
    for lo < hi && strings.index_byte("(<\"'`[\n", text[lo]) >= 0 {
        lo += 1
    }
    for hi > lo && strings.index_byte(")>\"'`],.;:!?\n", text[hi - 1]) >= 0 {
        hi -= 1
    }
    return lo, hi
}

// Where the shell stands; a new directory forgets what the old one resolved.
@(private = "file")
term_link_cwd :: proc(tm: ^Term) -> string {
    cwd := pty.terminal_cwd(&tm.t)
    if cwd != tm.cwd {
        term_resolved_clear(tm)
        delete(tm.cwd)
        tm.cwd = strings.clone(cwd)
    }
    return tm.cwd
}

@(private = "file")
term_link_value :: proc(tm: ^Term, tok, cwd: string) -> (string, bool) {
    if value, seen := tm.resolved[tok]; seen {
        return value, value != ""
    }
    value, ok := link_value(tok, cwd)
    if len(tm.resolved) >= TERM_RESOLVED_MAX {
        term_resolved_clear(tm)
    }
    tm.resolved[strings.clone(tok)] = ok ? strings.clone(value) : ""
    return value, ok
}

term_resolved_clear :: proc(tm: ^Term) {
    for k, v in tm.resolved {
        delete(k)
        delete(v)
    }
    clear(&tm.resolved)
}

// A cell as a document byte: the row's start plus its column walked to bytes, clamped to the
// row, and to the end of the rewrite for a row past it.
@(private = "file")
term_cell_off :: proc(tm: ^Term, at: [2]int, first, lo: int, text: string, starts: []int) -> int {
    k := at[0] - first
    if k >= len(starts) {
        return lo + len(text)
    }
    end := k + 1 < len(starts) ? starts[k + 1] - 1 : lo + len(text)
    return min(starts[k] + term_col_byte(tm, at[0] - tm.base, at[1]), end)
}

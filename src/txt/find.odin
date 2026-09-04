package txt

import "core:strings"

// Literal search over the document, line by line. LITERAL, not a regexp: PORTING.md §4.4 rules
// the regexp dialect is one decision made once in the open, and an engine belongs in plugin
// space over buf_chunk, not in the kernel.

// --- search ---

Find_Dir :: enum {
    Forward,
    Back,
}

// The next literal occurrence strictly past `from`, wrapping once. Line by line: a literal
// pattern cannot cross a line break, and doc_line borrows when the line sits in one piece.
doc_find :: proc(d: ^Doc, pattern: string, from: Pos, dir: Find_Dir) -> (Pos, bool) {
    n := doc_line_count(d)
    if pattern == "" || n == 0 {
        return {}, false
    }
    line := from.line
    // Strictly past `from`, so repeating a search advances instead of standing on its own match.
    ahead, behind := from.col + 1, from.col
    for _ in 0 ..= n {
        text := string(doc_line(d, line))
        if dir == .Forward {
            if ahead <= len(text) {
                if k := strings.index(text[ahead:], pattern); k >= 0 {
                    return {line, ahead + k}, true
                }
            }
            line, ahead = (line + 1) % n, 0
        } else {
            if k := strings.last_index(text[:min(behind, len(text))], pattern); k >= 0 {
                return {line, k}, true
            }
            line, behind = (line - 1 + n) % n, max(int)
        }
    }
    return {}, false
}

// Every literal occurrence, in document order, as [lo, hi) pairs. The replace-all batch and the
// match-all cursor verb ask the one question, so the scan is written once.
doc_find_all :: proc(d: ^Doc, pattern: string, alloc := context.temp_allocator) -> [][2]Pos {
    out := make([dynamic][2]Pos, 0, 16, alloc)
    if pattern == "" {
        return out[:]
    }
    for line in 0 ..< doc_line_count(d) {
        text := string(doc_line(d, line))
        at := 0
        for {
            k := strings.index(text[at:], pattern)
            if k < 0 {
                break
            }
            append(&out, [2]Pos{{line, at + k}, {line, at + k + len(pattern)}})
            at += k + len(pattern)
        }
    }
    return out[:]
}

// Every occurrence, as one batch and one undo entry. Offsets are taken before anything moves,
// which is what doc_apply's back-to-front rule needs.
doc_replace_all :: proc(d: ^Doc, pattern, with: string) -> int {
    hits := doc_find_all(d, pattern)
    if len(hits) == 0 {
        return 0
    }
    edits := make([]Edit, len(hits), context.temp_allocator)
    for h, i in hits {
        edits[i] = Edit{doc_off(d, h[0]), doc_off(d, h[1]), with, 0}
    }
    return doc_commit(d, edits) ? len(edits) : 0
}

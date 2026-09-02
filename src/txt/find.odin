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

// Every occurrence, as one batch and one undo entry. Offsets are taken before anything moves,
// which is what doc_apply's back-to-front rule needs.
doc_replace_all :: proc(d: ^Doc, pattern, with: string) -> int {
    if pattern == "" {
        return 0
    }
    edits := make([dynamic]Edit, 0, 16, context.temp_allocator)
    for line in 0 ..< doc_line_count(d) {
        text := string(doc_line(d, line))
        at := 0
        for {
            k := strings.index(text[at:], pattern)
            if k < 0 {
                break
            }
            lo := doc_off(d, Pos{line, at + k})
            append(&edits, Edit{lo, lo + len(pattern), with, 0})
            at += k + len(pattern)
        }
    }
    return len(edits) > 0 && doc_commit(d, edits[:]) ? len(edits) : 0
}

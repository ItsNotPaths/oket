package cl

import "core:strings"

// What opened a step. The zero value is `&&`, which is also the start of the line: the first
// step runs the way a step after a success does.
Op :: enum {
    And, // `&&`, or the start of the line: runs after a success
    Pipe, // `|`: runs after a success, taking what the step before it produced
    Or, // `||`: runs after a failure
}

// The operator's spelling, put back between coalescing shell steps for bash to read.
@(rodata)
SEP := [Op]string{.And = " && ", .Pipe = " | ", .Or = " || "}

// A segment and the operator that opened it.
Seg :: struct {
    text: string, // a slice of the line
    op:   Op,
}

// Split the way the shell would: only where the shell sees an operator, never inside quotes,
// after a backslash, or inside `...`, $(...), ${...}, $'...' or a subshell. Segments go on
// verbatim — nothing here expands or unquotes. An unclosed quote, brace or paren swallows the
// rest, as the shell would.
// Temp-allocated slices of s.
split :: proc(s: string, alloc := context.temp_allocator) -> []Seg {
    out := make([dynamic]Seg, 0, 4, alloc)
    depth: int // unquoted ( ) / $( ) nesting
    brace: int // ${ } nesting
    tick: bool // inside `...`
    start, i := 0, 0
    op: Op // what opened the segment being scanned
    word := true // a `#` is only a comment where a word starts
    for i < len(s) {
        c := s[i]
        switch {
        case c == '\'' || c == '"':
            _, n, ok := quoted_span(s[i:])
            i += ok ? n : len(s) - i
            word = false
            continue
        // bash's ANSI-C quoting, whose backslash hides the closing quote. Read as a plain
        // `'...'` the span ends at the `\'` and the operator after it splits a line the shell
        // reads as one word.
        case c == '$' && i + 1 < len(s) && s[i + 1] == '\'':
            end := quote_end(s, i + 1, true)
            i = end > 0 ? end : len(s)
            word = false
            continue
        // A parameter expansion is one word, the operators inside it included: `${x:-a|b}`.
        case c == '$' && i + 1 < len(s) && s[i + 1] == '{':
            brace += 1
            i += 2
            word = false
            continue
        case c == '}':
            brace = max(brace - 1, 0)
        // The rest of the line is the shell's comment, and it is DROPPED rather than passed on:
        // a step is injected on one line with its exit report after it (job.odin), so a comment
        // carried through would take the report with it and the chain would wait forever. That
        // reason is the shell's alone, and a builtin has no comments: `#` there is a ring slot
        // (PANELS.md §4), which is exactly a word that starts with one.
        case c == '#' && word && !tick && depth == 0 && brace == 0 && !is_builtin(s[start:i]):
            append(&out, Seg{s[start:i], op})
            return out[:]
        case c == '\\':
            i += 1 // escapes anything, `&` and `|` included
        case c == '`':
            tick = !tick
        case c == '(':
            depth += 1
        case c == ')':
            depth = max(depth - 1, 0)
        case c == '&' && !tick && depth == 0 && brace == 0 && i + 1 < len(s) && s[i + 1] == '&':
            append(&out, Seg{s[start:i], op})
            op, word = .And, true
            i += 2
            start = i
            continue
        // `||` is a step operator like `&&`: adjacent shell steps coalesce with it put back, so
        // it only decides anything at a boundary a builtin is on.
        case c == '|' && !tick && depth == 0 && brace == 0 && i + 1 < len(s) && s[i + 1] == '|':
            append(&out, Seg{s[start:i], op})
            op, word = .Or, true
            i += 2
            start = i
            continue
        // One `|` alone is ours. `|&` is the shell's pipe-with-stderr and stays inside a shell
        // step for bash to read.
        case c == '|' && !tick && depth == 0 && brace == 0 && (i + 1 >= len(s) || s[i + 1] != '&'):
            append(&out, Seg{s[start:i], op})
            op, word = .Pipe, true
            i += 1
            start = i
            continue
        // Exactly `|&`, never a catch-all: inside `${...}` or `...` the byte after a `|` can be
        // the closer the scan is waiting for.
        case c == '|' && i + 1 < len(s) && s[i + 1] == '&':
            i += 1 // the second byte of `|&`, skipped with the first
        }
        word = c == ' ' || c == '\t'
        i += 1
    }
    append(&out, Seg{s[start:], op})
    return out[:]
}

// Which half of the split a segment is in: a leading `:` names a builtin.
is_builtin :: proc(seg: string) -> bool {
    return strings.has_prefix(strings.trim_left_space(seg), ":")
}

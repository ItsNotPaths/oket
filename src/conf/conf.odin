package conf

import "core:strings"

// The one flat format (§4): `key = value` under `[section]` headers, the value being the rest of
// the line, unquoted. Both files the kernel WRITES are in it — `binds.conf` and `config.conf` —
// because a parse-modify-write cycle over a document model eats comments and ordering, and
// appending a line to this needs no cycle at all.
//
// Values arrive as strings. The read site parses what it wants, which is a parse_int at the
// handful of places that want a number.
//
// Rows point into `text`, so the caller keeps the bytes alive as long as the rows.

Row :: struct {
    section:    string, // "" until the first header
    key, value: string,
    line:       int, // 1-based, for the complaint and for describe's origin
}

// A bad row is reported and skipped, never fatal: one typo does not cost the file.
Error :: struct {
    line: int,
    why:  string,
}

parse :: proc(text: string, alloc := context.temp_allocator) -> (rows: []Row, errs: []Error) {
    out := make([dynamic]Row, alloc)
    bad := make([dynamic]Error, alloc)
    section := ""
    n := 0
    rest := text
    for raw in strings.split_lines_iterator(&rest) {
        n += 1
        row := strings.trim_space(raw)
        if row == "" || row[0] == '#' {
            continue
        }
        if row[0] == '[' {
            if row[len(row) - 1] != ']' {
                append(&bad, Error{n, "a section header wants a closing ]"})
                continue
            }
            section = strings.trim_space(row[1:len(row) - 1])
            continue
        }
        // Partitioned on the FIRST `=`, so a value may hold as many more as it likes: a bind's
        // command line is text, not an expression.
        key, sep, value := strings.partition(row, "=")
        key, value = strings.trim_space(key), strings.trim_space(value)
        if sep == "" || key == "" || value == "" {
            append(&bad, Error{n, "expected `key = value`"})
            continue
        }
        append(&out, Row{section, key, value, n})
    }
    return out[:], bad[:]
}

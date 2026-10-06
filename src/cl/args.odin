package cl

import "core:strings"

// A hole's value, quoted only when it would RE-PARSE (§8): the line is read again by the chain
// split and then by the shell, so a name holding a space or an `&&` has to survive both, and an
// ordinary path carries no quotes and stages readable.
sh_arg :: proc(s: string, alloc := context.temp_allocator) -> string {
    return sh_bare(s) ? s : sh_quote(s, alloc)
}

// An allowlist, not an escape list: anything unlisted goes through sh_quote rather than being
// judged harmless. Empty is not bare — it would vanish from the line.
@(private = "file")
sh_bare :: proc(s: string) -> bool {
    for i in 0 ..< len(s) {
        switch c := s[i]; {
        case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
        case c == '_', c == '-', c == '.', c == '/', c == '=', c == ':', c == '@', c == '+',
             c == ',':
        case:
            return false
        }
    }
    return len(s) > 0
}

// Single-quote s for the shell. An embedded quote closes, escapes and reopens ('\'') — safe in
// every POSIX shell.
sh_quote :: proc(s: string, alloc := context.allocator) -> string {
    b := strings.builder_make(alloc)
    strings.write_byte(&b, '\'')
    for i in 0 ..< len(s) {
        if s[i] == '\'' {
            strings.write_string(&b, `'\''`)
        } else {
            strings.write_byte(&b, s[i])
        }
    }
    strings.write_byte(&b, '\'')
    return strings.to_string(b)
}

first_field :: proc(s: string) -> string {
    i := 0
    for i < len(s) && !field_sep(s[i]) {
        i += 1
    }
    return s[:i]
}

// The ONE reading of where a field ends, so the address grammar and the picker that aims one
// cannot drift about what a bare `@` is surrounded by (PANELS.md §4, §6).
field_sep :: proc(c: byte) -> bool {
    return c == ' ' || c == '\t'
}

// The whole of `s` as ONE argument, quotes off. A hole fills quoted when its value would
// re-parse (§8), and a command taking a single value is where that line ends: it wants the
// value. A line that is not one quoted span from end to end is handed over as typed, because
// two arguments are the command's own to split.
arg_whole :: proc(s: string) -> string {
    if v, n, ok := quoted_value(s); ok && n == len(s) {
        return v
    }
    return s
}

// first_field, except a leading quote runs to its partner so a path with spaces works. Returns
// the span to skip and the value inside; an unclosed quote falls back to the field.
first_arg :: proc(s: string) -> (raw, value: string) {
    if v, n, ok := quoted_value(s); ok {
        return s[:n], v
    }
    f := first_field(s)
    return f, f
}

// The ONE reading of a quote here, so the chain splitter and the argument parsers cannot drift
// apart. `n` covers both quotes; ok is false when `s` does not open with a quote or the quote
// never closes.
@(private)
quoted_span :: proc(s: string) -> (inner: string, n: int, ok: bool) {
    if len(s) == 0 || (s[0] != '\'' && s[0] != '"') {
        return "", 0, false
    }
    end := quote_end(s, 0, s[0] == '"')
    return end > 0 ? s[1:end - 1] : "", end, end > 0
}

// Where the quote opened at `q` closes, one byte past its partner, or 0 when it never does.
// `esc` is whether a backslash hides that partner: `"..."` and `$'...'` say yes, `'...'` says
// no. The ONE reading of a closing quote, so an argument and the chain split cannot disagree
// about where a value ends.
@(private)
quote_end :: proc(s: string, q: int, esc: bool) -> int {
    for i := q + 1; i < len(s); i += 1 {
        if esc && s[i] == '\\' && i + 1 < len(s) {
            i += 1 // an escaped quote is content, not the partner
            continue
        }
        if s[i] == s[q] {
            return i + 1
        }
    }
    return 0
}

// The same span read as an ARGUMENT: double-quote escaping comes back off; a single-quoted span
// has nothing hidden to strip.
@(private = "file")
quoted_value :: proc(s: string) -> (value: string, n: int, ok: bool) {
    inner, span, found := quoted_span(s)
    if !found {
        return "", 0, false
    }
    return s[0] == '"' ? arg_unescape(inner) : inner, span, true
}

// Temp-allocated only when there is an escape to strip, so the common path borrows.
@(private = "file")
arg_unescape :: proc(s: string) -> string {
    if !strings.contains(s, "\\") {
        return s
    }
    b := strings.builder_make(context.temp_allocator)
    for i := 0; i < len(s); i += 1 {
        if s[i] == '\\' && i + 1 < len(s) {
            i += 1
        }
        strings.write_byte(&b, s[i])
    }
    return strings.to_string(b)
}

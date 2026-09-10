package main

import "core:fmt"
import "core:strings"

// A submitted line is a chain of segments split on `&&`, `||` and `|`, each a builtin (`:name`)
// or a shell command. Builtins run in-process; a shell step runs in the system session and the
// chain waits on its exit code.
//
// This is the half of §7's no-compiler extension path that is not the bind table: a chord runs
// a command line, lines chain, and a shell step is a first-class link. Binding a key to a shell
// pipeline over the file under point needs no plugin and no build.
//
// **`|` is not a pipe we implement.** Two adjacent shell steps COALESCE into one command and
// keep the operator, so `ls | grep x` reaches one `sh -c` whole and bash does its own piping.
// What `|` means here is only what bash cannot see: the two boundaries where text crosses
// between the shell and a document. `:sel` puts the selection on the next step's stdin, `:put`
// takes the last step's stdout and inserts it at point, and the chain carries exactly one
// string between them. So `:sel | sort -u | :put` is a source, a shell pipeline of any length,
// and a sink — three steps, one carried string, and no shell grammar reimplemented.

// What opened a step. The zero value is `&&`, which is also the start of the line: the first
// step runs the way a step after a success does.
CL_Op :: enum {
    And, // `&&`, or the start of the line: runs after a success
    Pipe, // `|`: runs after a success, taking what the step before it produced
    Or, // `||`: runs after a failure
}

// The operator's spelling, put back between coalescing shell steps for bash to read.
@(rodata)
CL_SEP := [CL_Op]string{.And = " && ", .Pipe = " | ", .Or = " || "}

CL_Step :: struct {
    shell: bool,
    op:    CL_Op,
    text:  string, // owned; a builtin's `:` already stripped
}

Chain :: struct {
    steps:   [dynamic]CL_Step,
    idx:     int,
    waiting: bool, // a shell step is out; its exit advances or stops the chain
    // Did the last step that RAN fail. A skipped step carries it forward, which is the shell's
    // own flat reading of `a && b || c` — no precedence, left to right.
    failed:  bool,
    // Bumped by every clear, so a builtin that replaced the chain out from under the pump
    // (`:pluginify` hands it a new line) is detected rather than stepped past.
    era:     u64,
    // The one string that crosses between a document and the shell. Owned.
    feed:    string,
    fed:     bool, // a step has produced text; "" is a legitimate value, so this is not len()
}

// `:do`'s cap. A queued line may queue lines of its own, and this is the one guard against a
// line that regenerates itself forever.
QUEUE_MAX :: 512

// Is a step after this one opened by a `|` — a `:put` waiting for what the shell is about to
// write. The one thing that makes the kernel stage a step's stdout (sh_run) rather than leave
// it on screen.
chain_wants_feed :: proc(a: ^App) -> bool {
    next := a.chain.idx + 1
    return next < len(a.chain.steps) && a.chain.steps[next].op == .Pipe
}

// Did a `|` open this step with a feed for it to take — `:put`/`:do`'s gate, and what sends
// the feed to a shell step's stdin (chain_pump).
chain_piped :: proc(a: ^App, step: CL_Step) -> bool {
    return step.op == .Pipe && a.chain.fed
}

// Is a failure this step reports one the chain itself will answer — an `||` still ahead. The
// arm that runs is the response, so nothing surfaces N0 over it (sh_pump).
chain_rescued :: proc(a: ^App) -> bool {
    for i in a.chain.idx + 1 ..< len(a.chain.steps) {
        if a.chain.steps[i].op == .Or {
            return true
        }
    }
    return false
}

chain_busy :: proc(a: ^App) -> bool {
    return a.chain.waiting || len(a.chain.steps) > 0 || len(a.queue) > 0
}

chain_clear :: proc(a: ^App) {
    for s in a.chain.steps {
        delete(s.text)
    }
    delete(a.chain.steps)
    delete(a.chain.feed)
    era := a.chain.era + 1
    a.chain = {}
    a.chain.era = era
}

queue_destroy :: proc(a: ^App) {
    queue_clear(a)
    delete(a.queue)
    a.queue = nil
}

// What one step handed on, taken by the next. Owned by the chain; replacing it frees the last.
chain_feed :: proc(a: ^App, text: string) {
    delete(a.chain.feed)
    a.chain.feed = strings.clone(text)
    a.chain.fed = true
}

// A new line abandons any half-finished chain; a job already running finishes on its own.
cl_exec :: proc(a: ^App, line: string) {
    cl_parse(a, line)
    chain_pump(a)
}

// How deep an alias may expand an alias. The guard against a name that names itself.
ALIAS_DEPTH :: 8

// Chain-building without execution, split out so the parse is testable on its own.
cl_parse :: proc(a: ^App, line: string) {
    chain_clear(a)
    cl_parse_into(a, line, .And, 0)
}

// One line's segments, appended. `op0` replaces the first segment's opener — an alias body
// keeps the operator its name was called with, so `:sel | :up` pipes into the body's first
// step — and `depth` is where alias-in-alias stops.
@(private = "file")
cl_parse_into :: proc(a: ^App, line: string, op0: CL_Op, depth: int) {
    for seg, i in cl_split_chain(strings.trim_space(line)) {
        // Segment ZERO only: an empty first segment (`|| x` opens the line) consumes the
        // override, so the `||` keeps its own operator and stays a skipped step.
        op := i == 0 ? op0 : seg.op
        s := strings.trim_space(seg.text)
        if s == "" {
            continue
        }
        if seg_builtin(s) {
            name := strings.trim_space(s[1:])
            if name == "" {
                continue // a bare `:` names no builtin
            }
            // A whole step that is one alias name expands IN PLACE, so the chain that runs is
            // one you could have typed. With arguments or past the depth cap it goes on as a
            // step, and cl_builtin says which refusal it was.
            if depth < ALIAS_DEPTH && name == first_field(name) {
                if sub := alias_expansion(a, name); sub != "" {
                    cl_parse_into(a, sub, op, depth + 1)
                    continue
                }
            }
            append(&a.chain.steps, CL_Step{false, op, strings.clone(name)})
            continue
        }
        // Two shell steps in a row are one command: the operator goes back in and the shell
        // reads it, which is what keeps a pipeline bash's job and not ours.
        if n := len(a.chain.steps); n > 0 && a.chain.steps[n - 1].shell {
            prev := &a.chain.steps[n - 1]
            joined := strings.concatenate({prev.text, CL_SEP[op], s})
            delete(prev.text)
            prev.text = joined
            continue
        }
        append(&a.chain.steps, CL_Step{true, op, strings.clone(s)})
    }
}

// The line `:name` stands for, "" when it must not expand: builtins and plugin commands keep
// a clashing name, so an alias can never change what an existing verb does.
@(private = "file")
alias_expansion :: proc(a: ^App, name: string) -> string {
    if _, builtin := builtin_named(name); builtin {
        return ""
    }
    if _, registered := plug_cmd_named(a, name); registered {
        return ""
    }
    return config_alias_line(&a.config, name)
}

// A segment and the operator that opened it.
CL_Seg :: struct {
    text: string, // a slice of the line
    op:   CL_Op,
}

// Split the way the shell would: only where the shell sees an operator, never inside quotes,
// after a backslash, or inside `...`, $(...), ${...}, $'...' or a subshell. Segments go on
// verbatim — nothing here expands or unquotes. An unclosed quote, brace or paren swallows the
// rest, as the shell would.
// Temp-allocated slices of s.
cl_split_chain :: proc(s: string, alloc := context.temp_allocator) -> []CL_Seg {
    out := make([dynamic]CL_Seg, 0, 4, alloc)
    depth: int // unquoted ( ) / $( ) nesting
    brace: int // ${ } nesting
    tick: bool // inside `...`
    start, i := 0, 0
    op: CL_Op // what opened the segment being scanned
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
        case c == '#' && word && !tick && depth == 0 && brace == 0 && !seg_builtin(s[start:i]):
            append(&out, CL_Seg{s[start:i], op})
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
            append(&out, CL_Seg{s[start:i], op})
            op, word = .And, true
            i += 2
            start = i
            continue
        // `||` is a step operator like `&&`: adjacent shell steps coalesce with it put back, so
        // it only decides anything at a boundary a builtin is on.
        case c == '|' && !tick && depth == 0 && brace == 0 && i + 1 < len(s) && s[i + 1] == '|':
            append(&out, CL_Seg{s[start:i], op})
            op, word = .Or, true
            i += 2
            start = i
            continue
        // One `|` alone is ours. `|&` is the shell's pipe-with-stderr and stays inside a shell
        // step for bash to read.
        case c == '|' && !tick && depth == 0 && brace == 0 && (i + 1 >= len(s) || s[i + 1] != '&'):
            append(&out, CL_Seg{s[start:i], op})
            op, word = .Pipe, true
            i += 1
            start = i
            continue
        // Named exactly rather than left as a catch-all: any `|` an operator case declines
        // used to eat the byte after it, and inside `${...}` or `...` that byte can be the
        // closer the scan is waiting for.
        case c == '|' && i + 1 < len(s) && s[i + 1] == '&':
            i += 1 // the second byte of `|&`, skipped with the first
        }
        word = c == ' ' || c == '\t'
        i += 1
    }
    append(&out, CL_Seg{s[start:], op})
    return out[:]
}

// Which half of the split a segment is in: a leading `:` names a builtin.
@(private = "file")
seg_builtin :: proc(seg: string) -> bool {
    return strings.has_prefix(strings.trim_left_space(seg), ":")
}

// Advance as far as this frame allows: builtins run inline, a shell step goes out and the chain
// waits on its exit code. A chain that ends takes the next `:do` line, so the queue drains here
// and nowhere else.
chain_pump :: proc(a: ^App) {
    ch := &a.chain
    if ch.waiting {
        return
    }
    for {
        for ch.idx < len(ch.steps) {
            step := ch.steps[ch.idx]
            // `&&` and `|` run on a success, `||` on a failure, and a skipped step carries the
            // verdict forward — the shell's own flat reading, no precedence.
            if step.op == .Or ? !ch.failed : ch.failed {
                ch.idx += 1
                continue
            }
            if step.shell {
                // Its stdin is what the step before piped, and its stdout becomes the next
                // step's feed when it finishes (sh_pump).
                if !sh_run(a, step.text, ch.feed, chain_piped(a, step)) {
                    chain_clear(a)
                    queue_clear(a) // a step that cannot even go out is nothing to keep feeding
                    return
                }
                ch.waiting = true
                return
            }
            era := ch.era
            ok := cl_builtin(a, step)
            if era != ch.era {
                return // the builtin replaced the chain (`:pluginify` does); it is not ours to step
            }
            ch.failed = !ok
            ch.idx += 1
        }
        chain_clear(a)
        if !queue_next(a) {
            return
        }
    }
}

// The step the chain was waiting on reported its exit. A failure is not a stop any more than a
// builtin's is: the skip walk above answers it, and with no `||` ahead it walks off the end.
cl_job_done :: proc(a: ^App, code: int) {
    a.chain.waiting = false
    a.chain.failed = code != 0
    a.chain.idx += 1
    chain_pump(a)
}

// --- the queue (`:do`) ---

// The next queued line, parsed into the chain the pump is about to run. Echoed into N0 first,
// so a loop leaves a transcript: what ran is scrollback, not something to reconstruct.
@(private = "file")
queue_next :: proc(a: ^App) -> bool {
    if len(a.queue) == 0 {
        return false
    }
    line := a.queue[0]
    ordered_remove(&a.queue, 0)
    sys_println(a, fmt.tprintf("%s%s", CL_PROMPT, line))
    cl_parse(a, line)
    delete(line)
    return true
}

queue_clear :: proc(a: ^App) {
    for line in a.queue {
        delete(line)
    }
    clear(&a.queue)
}

// --- reading a line ---

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
@(private = "file")
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
@(private = "file")
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

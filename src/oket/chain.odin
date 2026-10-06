package main

import "core:fmt"
import "core:strings"
import "../cl"

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

CL_Step :: struct {
    shell: bool,
    op:    cl.Op,
    text:  string, // owned; a builtin's `:` already stripped
}

// (hole cmd-chain :tags shared :sev gap) the chain runs on ^App (a.chain, a.queue, aliases, sh_run); it must move into cl as a pulled state machine.
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

// Is the step the chain is on the last thing it has to do. What tells a step you are watching
// run from one the chain is going to act on the answer of (job.odin).
chain_last_step :: proc(a: ^App) -> bool {
    return a.chain.idx + 1 >= len(a.chain.steps) && len(a.queue) == 0
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
cl_parse_into :: proc(a: ^App, line: string, op0: cl.Op, depth: int) {
    for seg, i in cl.split(strings.trim_space(line)) {
        // Segment ZERO only: an empty first segment (`|| x` opens the line) consumes the
        // override, so the `||` keeps its own operator and stays a skipped step.
        op := i == 0 ? op0 : seg.op
        s := strings.trim_space(seg.text)
        if s == "" {
            continue
        }
        if cl.is_builtin(s) {
            name := strings.trim_space(s[1:])
            if name == "" {
                continue // a bare `:` names no builtin
            }
            // A whole step that is one alias name expands IN PLACE, so the chain that runs is
            // one you could have typed. With arguments or past the depth cap it goes on as a
            // step, and cl_builtin says which refusal it was.
            if depth < ALIAS_DEPTH && name == cl.first_field(name) {
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
            joined := strings.concatenate({prev.text, cl.SEP[op], s})
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

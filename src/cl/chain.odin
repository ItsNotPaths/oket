package cl

import "core:strings"

// A submitted line is a chain of segments split on `&&`, `||` and `|`, each a builtin (`:name`)
// or a shell command. Builtins run in-process; a shell step runs in the host's shell and the
// chain waits on its exit code.
//
// **`|` is not a pipe we implement.** Two adjacent shell steps COALESCE into one command and
// keep the operator, so `ls | grep x` reaches one `sh -c` whole and bash does its own piping.
// What `|` means here is only what bash cannot see: the two boundaries where text crosses
// between the shell and a document. `:sel` puts the selection on the next step's stdin, `:put`
// takes the last step's stdout and inserts it at point, and the chain carries exactly one
// string between them. So `:sel | sort -u | :put` is a source, a shell pipeline of any length,
// and a sink — three steps, one carried string, and no shell grammar reimplemented.
//
// The chain is pulled: `next` names the step to run, the host runs it, and `done` or
// `job_done` hands the verdict back. Nothing here calls out.

Step :: struct {
    shell: bool,
    op:    Op,
    text:  string, // owned; a builtin's `:` already stripped
}

Chain :: struct {
    steps:   [dynamic]Step,
    idx:     int,
    waiting: bool, // the host sent a shell step out; job_done advances the chain
    // Did the last step that RAN fail. A skipped step carries it forward, which is the shell's
    // own flat reading of `a && b || c` — no precedence, left to right.
    failed:  bool,
    // Bumped by every reset, so a builtin that replaced the chain out from under the host's
    // loop (`:pluginify` hands it a new line) is detected rather than stepped past.
    era:     u64,
    // The one string that crosses between a document and the shell, nil until a step produces
    // one: "" is a legitimate value. Owned.
    feed:    Maybe(string),
    // `:do`'s pending lines, each run as its own chain once this one ends. A reset keeps them:
    // a queued line's parse resets the chain and must not eat the lines behind it.
    queue:   [dynamic]string,
}

// `:do`'s cap. A queued line may queue lines of its own, and this is the one guard against a
// line that regenerates itself forever.
QUEUE_MAX :: 512

// How deep an alias may expand an alias. The guard against a name that names itself.
@(private = "file")
ALIAS_DEPTH :: 8

// A new chain from `line`. `alias` answers the line `:name` stands for, "" when it must not
// expand; `host` is handed back to it.
parse :: proc(ch: ^Chain, line: string, host: $H, alias: proc(host: H, name: string) -> string) {
    reset(ch)
    parse_into(ch, line, .And, 0, host, alias)
}

// One line's segments, appended. `op0` replaces the first segment's opener — an alias body
// keeps the operator its name was called with, so `:sel | :up` pipes into the body's first
// step — and `depth` is where alias-in-alias stops.
@(private = "file")
parse_into :: proc(ch: ^Chain, line: string, op0: Op, depth: int, host: $H,
                   alias: proc(host: H, name: string) -> string) {
    for seg, i in split(strings.trim_space(line)) {
        // Segment ZERO only: an empty first segment (`|| x` opens the line) consumes the
        // override, so the `||` keeps its own operator and stays a skipped step.
        op := i == 0 ? op0 : seg.op
        s := strings.trim_space(seg.text)
        if s == "" {
            continue
        }
        if is_builtin(s) {
            name := strings.trim_space(s[1:])
            if name == "" {
                continue // a bare `:` names no builtin
            }
            // A whole step that is one alias name expands IN PLACE, so the chain that runs is
            // one you could have typed. With arguments or past the depth cap it goes on as a
            // step, and the host says which refusal it was.
            if depth < ALIAS_DEPTH && name == first_field(name) {
                if sub := alias(host, name); sub != "" {
                    parse_into(ch, sub, op, depth + 1, host, alias)
                    continue
                }
            }
            append(&ch.steps, Step{false, op, strings.clone(name)})
            continue
        }
        // Two shell steps in a row are one command: the operator goes back in and the shell
        // reads it, which is what keeps a pipeline bash's job and not ours.
        if n := len(ch.steps); n > 0 && ch.steps[n - 1].shell {
            prev := &ch.steps[n - 1]
            joined := strings.concatenate({prev.text, SEP[op], s})
            delete(prev.text)
            prev.text = joined
            continue
        }
        append(&ch.steps, Step{true, op, strings.clone(s)})
    }
}

// The step to run now, false when the chain waits on a shell step or has ended; an ended chain
// is reset, so only the queue can keep it busy. `&&` and `|` run on a success, `||` on a
// failure, and a skipped step carries the verdict forward.
next :: proc(ch: ^Chain) -> (Step, bool) {
    if ch.waiting {
        return {}, false
    }
    for ; ch.idx < len(ch.steps); ch.idx += 1 {
        step := ch.steps[ch.idx]
        if step.op == .Or ? ch.failed : !ch.failed {
            return step, true
        }
    }
    if len(ch.steps) > 0 {
        reset(ch)
    }
    return {}, false
}

// A builtin's verdict on the step `next` named.
done :: proc(ch: ^Chain, ok: bool) {
    ch.failed = !ok
    ch.idx += 1
}

// The shell step the chain waited on reported its exit. A failure is not a stop any more than a
// builtin's is: the skip walk in `next` answers it, and with no `||` ahead it walks off the end.
job_done :: proc(ch: ^Chain, code: int) {
    ch.waiting = false
    done(ch, code == 0)
}

// Is a step after this one opened by a `|` — a `:put` waiting for what the shell is about to
// write. What makes a host stage a step's stdout rather than leave it on screen.
wants_feed :: proc(ch: ^Chain) -> bool {
    after := ch.idx + 1
    return after < len(ch.steps) && ch.steps[after].op == .Pipe
}

// The feed this step takes, when a `|` opened it and a step before produced one: `:put`/`:do`'s
// input, and a shell step's stdin.
piped :: proc(ch: ^Chain, step: Step) -> (string, bool) {
    if step.op != .Pipe {
        return "", false
    }
    return ch.feed.?
}

// Is a failure this step reports one the chain itself will answer — an `||` still ahead. The
// arm that runs is the response, so the host need not surface the failure.
rescued :: proc(ch: ^Chain) -> bool {
    for i in ch.idx + 1 ..< len(ch.steps) {
        if ch.steps[i].op == .Or {
            return true
        }
    }
    return false
}

// Is the step the chain is on the last thing it has to do, queue included.
last_step :: proc(ch: ^Chain) -> bool {
    return ch.idx + 1 >= len(ch.steps) && len(ch.queue) == 0
}

busy :: proc(ch: ^Chain) -> bool {
    return ch.waiting || len(ch.steps) > 0 || len(ch.queue) > 0
}

// What one step handed on, taken by the next. Replacing it frees the last.
feed_set :: proc(ch: ^Chain, text: string) {
    delete(ch.feed.? or_else "")
    ch.feed = strings.clone(text)
}

// The next queued line, owned by the caller.
dequeue :: proc(ch: ^Chain) -> (line: string, ok: bool) {
    if len(ch.queue) == 0 {
        return "", false
    }
    line = ch.queue[0]
    ordered_remove(&ch.queue, 0)
    return line, true
}

// The steps and the feed go; the queue stays.
reset :: proc(ch: ^Chain) {
    for s in ch.steps {
        delete(s.text)
    }
    delete(ch.steps)
    delete(ch.feed.? or_else "")
    ch^ = {era = ch.era + 1, queue = ch.queue}
}

queue_clear :: proc(ch: ^Chain) {
    for line in ch.queue {
        delete(line)
    }
    clear(&ch.queue)
}

destroy :: proc(ch: ^Chain) {
    reset(ch)
    queue_clear(ch)
    delete(ch.queue)
    ch.queue = nil
}

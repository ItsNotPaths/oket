package main

import "core:fmt"
import "../cl"

// The command line's host (src/cl). This is the half of §7's no-compiler extension path that is
// not the bind table: a chord runs a command line, lines chain, and a shell step is a
// first-class link. Binding a key to a shell pipeline over the file under point needs no plugin
// and no build.

// Named here because App's own `cl` field hides the package inside the struct.
Chain :: cl.Chain

// A new line abandons any half-finished chain; a job already running finishes on its own.
cl_exec :: proc(a: ^App, line: string) {
    if cl_start(a, line) {
        chain_pump(a)
    }
}

// The parse, and the fields under point taken once for every step. A `$o_` name nothing here
// carries stops the line before any of it runs.
@(private = "file")
cl_start :: proc(a: ^App, line: string) -> bool {
    cl_parse(a, line)
    cl.vars_set(&a.chain, vars_under_point(a))
    if name, gap := cl.vars_missing(&a.chain); gap {
        vars_say_missing(a, name)
        cl.reset(&a.chain)
        return false
    }
    return true
}

// A key's line, and the live re-run's. One builtin step runs directly, outside `a.chain`, so a
// key never abandons a chain that is waiting; anything longer is a chain of its own. A line the
// builtin queued runs now, or after the waiting chain ends.
line_run :: proc(a: ^App, line: string) {
    ch: cl.Chain
    defer cl.destroy(&ch)
    cl.parse(&ch, line, a, alias_expansion, takes_line)
    if len(ch.steps) != 1 || ch.steps[0].shell {
        cl_exec(a, line)
        return
    }
    step := ch.steps[0]
    text, missing, filled := cl.fill(vars_under_point(a), step.text)
    if !filled {
        vars_say_missing(a, missing)
        return
    }
    step.text = text
    cl_builtin(a, step)
    chain_pump(a)
}

// Chain-building without execution, split out so the parse is testable on its own.
cl_parse :: proc(a: ^App, line: string) {
    cl.parse(&a.chain, line, a, alias_expansion, takes_line)
}

@(private = "file")
takes_line :: proc(_: ^App, name: string) -> bool {
    return name == "stage"
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
// waits on its exit code (sh_pump). A chain that ends takes the next `:do` line, so the queue
// drains here and nowhere else.
chain_pump :: proc(a: ^App) {
    ch := &a.chain
    for !ch.waiting {
        step, ok := cl.next(ch)
        if !ok {
            line := cl.dequeue(ch) or_break
            // Echoed into N0 first, so a loop leaves a transcript: what ran is scrollback.
            sys_println(a, fmt.tprintf("%s%s", CL_PROMPT, line))
            cl_start(a, line)
            delete(line)
            continue
        }
        if step.shell {
            feed, fed := cl.piped(ch, step)
            if !sh_run(a, step.text, feed, fed, step.feeds) {
                cl.reset(ch)
                cl.queue_clear(ch) // a step that cannot even go out is nothing to keep feeding
                return
            }
            ch.waiting = true
            return
        }
        era := ch.era
        step.text, _, _ = cl.fill(ch.vars, step.text) // cl_start checked every name is there
        ok = cl_builtin(a, step)
        if era != ch.era {
            return // the builtin replaced the chain (`:pluginify` does); it is not ours to step
        }
        cl.done(ch, ok)
    }
}

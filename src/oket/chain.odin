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
    cl_parse(a, line)
    chain_pump(a)
}

// Chain-building without execution, split out so the parse is testable on its own.
cl_parse :: proc(a: ^App, line: string) {
    cl.parse(&a.chain, line, a, alias_expansion)
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
            cl_parse(a, line)
            delete(line)
            continue
        }
        if step.shell {
            if !sh_run(a, step.text, ch.feed, cl.piped(ch, step)) {
                cl.reset(ch)
                cl.queue_clear(ch) // a step that cannot even go out is nothing to keep feeding
                return
            }
            ch.waiting = true
            return
        }
        era := ch.era
        ok = cl_builtin(a, step)
        if era != ch.era {
            return // the builtin replaced the chain (`:pluginify` does); it is not ours to step
        }
        cl.done(ch, ok)
    }
}

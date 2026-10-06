package tests

import "core:strings"
import "core:testing"
import "../cl"

// The `cl` package runs a chain for any host, not only oket's App: llem drives the same
// grammar. A host that is a plain struct, builtins that answer by name, and no shell.

@(private = "file")
Host :: struct {
    ran:     [dynamic]string,
    aliases: map[string]string,
}

@(private = "file")
host_alias :: proc(h: ^Host, name: string) -> string {
    return h.aliases[name]
}

// Runs builtins until the chain ends or waits; `fail` is the one builtin that fails.
@(private = "file")
host_run :: proc(h: ^Host, ch: ^cl.Chain, line: string) {
    cl.parse(ch, line, h, host_alias)
    for step in cl.next(ch) {
        if step.shell {
            ch.waiting = true
            return
        }
        append(&h.ran, strings.clone(step.text, context.temp_allocator))
        cl.done(ch, step.text != "fail")
    }
}

@(private = "file")
host_destroy :: proc(h: ^Host, ch: ^cl.Chain) {
    delete(h.ran)
    delete(h.aliases)
    cl.destroy(ch)
}

@(test)
a_host_with_no_app_runs_a_chain :: proc(t: ^testing.T) {
    h: Host
    ch: cl.Chain
    defer host_destroy(&h, &ch)
    h.aliases["both"] = ":one && :two"

    host_run(&h, &ch, ":fail && :skipped || :rescue && :both")
    testing.expect_value(t, len(h.ran), 4)
    if len(h.ran) == 4 {
        testing.expect_value(t, h.ran[0], "fail")
        testing.expect_value(t, h.ran[1], "rescue")
        testing.expect_value(t, h.ran[2], "one")
        testing.expect_value(t, h.ran[3], "two")
    }
    testing.expect(t, !cl.busy(&ch))
}

@(test)
a_shell_step_holds_the_chain_until_its_exit :: proc(t: ^testing.T) {
    h: Host
    ch: cl.Chain
    defer host_destroy(&h, &ch)

    host_run(&h, &ch, ":first && make || :after")
    testing.expect_value(t, len(h.ran), 1)
    testing.expect(t, cl.busy(&ch))
    _, runnable := cl.next(&ch)
    testing.expect(t, !runnable)

    cl.job_done(&ch, 2)
    step, ok := cl.next(&ch)
    testing.expect(t, ok)
    testing.expect_value(t, step.text, "after")
}

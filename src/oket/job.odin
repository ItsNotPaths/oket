package main

import "core:fmt"
import "core:os"
import "core:strings"
import "../pty"

// The system session (§11), and the one shell step a chain has out at a time.
//
// N# is where everything oket itself runs goes: a chain's shell steps, and what a builtin has
// to say at more than one line's worth. One kernel-owned session in the ring's reserved slot,
// reached by alt+0 and outside the alt+1..9 rotation. It surfaces itself on a non-zero exit and
// on nothing else, which is a rule and not a mode — a prompt blocking a chain with no visible
// symptom is the invisible state §1 exists to kill.
//
// It is a real PTY running a real shell, the same kind of document alt+t opens (term.odin), so
// a step that prompts is something you can answer rather than a chain wedged behind a question
// nobody can see. What a step costs the kernel is two strings: the line injected, and the exit
// code the shell reports back through a private OSC.

// What a step is injected as. The printf reports the group's exit code, and `cat` puts a
// captured step's output on screen AFTER the report — the kernel reads the file, so nothing is
// waiting on the screen.
//
// The line is echoed by the shell's own line editor, which is why it is kept as short as it
// can be: the subshell appears only when a redirect needs one, because `a && b < f` would bind
// the redirect to `b` alone. Everything that can be said once is said at spawn instead.
//
// POSIX sh, which is what an injected line has to be. The child is the user's $SHELL and this
// is the one place the kernel writes a command for it to read.
@(private = "file")
STEP :: "%s ;printf '\\033]%d;%d;%%d\\007' \"$?\"%s\n"

// Said once per session, so no step has to carry it. A pager blocking on a keypress is a chain
// stalled behind a question, which is the invisible state N# exists to make visible.
//
// What ships BESIDE the binary goes on the path with it, so a chain reaches `oket-grammar` or
// `stage.sh` by name whether or not oket itself was installed onto anybody's PATH — which is
// what lets a bind row name a tool instead of a location.
@(private = "file")
SETUP :: "export GIT_PAGER=cat PAGER=cat\n"

@(private = "file")
setup_line :: proc(a: ^App) -> string {
    if a.home == "" {
        return SETUP
    }
    return fmt.tprintf("export GIT_PAGER=cat PAGER=cat PATH=\"$PATH\":%s\n", sh_arg(a.home))
}

Job :: struct {
    live:     bool,
    id:       u64, // the injection this chain waits on; a stale report carries another
    feed:     string, // owned; the temp file holding the step's stdin, "" when it has none
    out:      string, // owned; the temp file its stdout was staged in, "" when nothing wanted it
    captured: bool,
}

// Send a step out. Its stdin is what the step before it piped, staged through a temporary file
// rather than a pipe: nothing reads a stdin pipe until the child runs, so a feed larger than
// one pipe buffer would block us before the child that drains it even exists. Its stdout is
// staged the same way when the chain has a `:put` waiting for it, and left alone otherwise, so
// an ordinary step is live output and not a buffer that appears when it ends.
sh_run :: proc(a: ^App, cmd, feed: string, fed: bool) -> bool {
    if a.job.live {
        message_set(a, "a shell step is still running")
        return false
    }
    tm := sys_term(a)
    if tm == nil {
        return false
    }
    job_end(a) // the last step's staging, kept until now so its `cat` could finish with it
    a.sys_seq += 1
    a.job = Job{live = true, id = a.sys_seq, captured = chain_wants_feed(a)}
    tm.t.exit_ready = false // any report still standing belongs to a step that is over

    if fed {
        a.job.feed = job_stage(a, "oket-feed-*", feed)
    }
    if a.job.captured {
        a.job.out = job_stage(a, "oket-out-*", "")
    }
    body := cmd
    if a.job.feed != "" || a.job.out != "" {
        body = fmt.tprintf(
            "(%s)%s%s",
            cmd,
            a.job.feed != "" ? fmt.tprintf(" < %s", sh_quote(a.job.feed, context.temp_allocator)) : "",
            a.job.out != "" ? fmt.tprintf(" > %s 2>&1", sh_quote(a.job.out, context.temp_allocator)) : "",
        )
    }
    line := fmt.tprintf(
        STEP,
        body,
        pty.OSC_EXIT_TAG,
        a.job.id,
        a.job.out != "" ? fmt.tprintf("; cat %s", sh_quote(a.job.out, context.temp_allocator)) : "",
    )
    pty.terminal_write(&tm.t, transmute([]u8)line)
    return true
}

// After the frame's drains: the exit code N# reported, and the step's staged output to whatever
// the chain does next.
sh_pump :: proc(a: ^App) {
    if !a.job.live {
        return
    }
    tm := term_of(a, a.ring.system.doc)
    if tm == nil || !pty.terminal_alive(&tm.t) {
        // The step took the shell down with it — `exit` at the top level does exactly that,
        // because a step is not wrapped in a subshell and `cd` is why. Surface it: a dead N#
        // showing its last screen is the answer, and the next step spawns a fresh one.
        message_set(a, "the system session's shell exited mid-step")
        ring_show_system(a)
        job_end(a)
        chain_clear(a)
        return
    }
    if !tm.t.exit_ready || tm.t.exit_id != a.job.id {
        return
    }
    tm.t.exit_ready = false
    code, captured := tm.t.exit_code, a.job.captured
    if captured {
        if raw, err := os.read_entire_file(a.job.out, context.temp_allocator); err == nil {
            chain_feed(a, string(raw))
        }
    }
    a.job.live = false // the staging survives until the next step: `cat` is still reading it
    // §11: a failure surfaces N#. Except where the chain was reading this step's output, which
    // means the answer lands in the document you are looking at and being thrown to a terminal
    // is the wrong place to be told.
    if code != 0 {
        if captured {
            message_set(a, fmt.tprintf("the shell step exited %d", code))
        } else {
            ring_show_system(a)
        }
    }
    cl_job_done(a, code)
}

// Everything the job staged, and the struct back to rest. The chain is not touched: a caller
// mid-`cl_job_done` is the one who decides what happens next.
@(private = "file")
job_end :: proc(a: ^App) {
    for path in ([?]string{a.job.feed, a.job.out}) {
        if path != "" {
            os.remove(path)
            delete(path)
        }
    }
    a.job = {}
}

job_destroy :: proc(a: ^App) {
    job_end(a)
}

// A temp file the shell reads or writes by name. Empty on failure, which reads as "not staged"
// everywhere it is used, so a full disk costs the step its pipe and not the kernel.
@(private = "file")
job_stage :: proc(a: ^App, pattern, text: string) -> string {
    f, err := os.create_temp_file("", pattern)
    if err != nil {
        message_set(a, fmt.tprintf("cannot stage a shell step: %v", err))
        return ""
    }
    defer os.close(f)
    if text != "" {
        os.write(f, transmute([]u8)text)
    }
    return strings.clone(os.name(f))
}

// --- N# ---

// The system session's document, spawned the first time anything needs it and again after its
// shell exits. A dead N# is not an error state to report: the next thing that runs gets a fresh
// shell, which is what a terminal multiplexer does.
sys_slot :: proc(a: ^App) -> ^Slot {
    if a.ring.system.live {
        if tm := term_of(a, a.ring.system.doc); tm != nil && pty.terminal_alive(&tm.t) {
            return &a.ring.system
        }
        doc_close(a, a.ring.system.doc)
        a.ring.system = {}
    }
    id, made := term_open(a)
    if !made {
        return nil
    }
    a.ring.system = Slot{id, {}, true}
    if tm := term_of(a, id); tm != nil {
        pty.terminal_write(&tm.t, transmute([]u8)setup_line(a))
    }
    return &a.ring.system
}

sys_term :: proc(a: ^App) -> ^Term {
    s := sys_slot(a)
    return s == nil ? nil : term_of(a, s.doc)
}

// What the kernel itself has to say, straight into the session's screen. Fed to the VT as if
// the shell had written it, so it scrolls, colours and copies like everything else there and no
// second transcript exists to keep in step.
sys_print :: proc(a: ^App, text: string) {
    tm := sys_term(a)
    if tm == nil || text == "" {
        return
    }
    // A bare newline leaves the cursor in the column it was in: on a terminal the carriage
    // return is the other half of the ending.
    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< len(text) {
        if text[i] == '\n' && (i == 0 || text[i - 1] != '\r') {
            strings.write_byte(&b, '\r')
        }
        strings.write_byte(&b, text[i])
    }
    pty.terminal_feed(&tm.t, transmute([]u8)strings.to_string(b))
}

sys_println :: proc(a: ^App, line: string) {
    sys_print(a, fmt.tprintf("%s\n", line))
}

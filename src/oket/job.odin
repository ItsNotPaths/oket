package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "../desc"
import "../store"
import "../txt"
import "../view"

// The system session (§11), and the one shell step a chain has out at a time.
//
// N# is where everything oket itself runs goes: a chain's shell steps, and what a builtin has
// to say at more than one line's worth. One kernel-owned document in the ring's reserved slot,
// reached by alt+0 and outside the alt+1..9 rotation. It surfaces itself on a non-zero exit and
// on nothing else, which is a rule and not a mode — a prompt blocking a chain with no visible
// symptom is the invisible state §1 exists to kill.
//
// A step runs on a kernel-owned worker thread (§9: the kernel does the blocking work, plugins
// never see a thread). Stage 6 replaces the document with a real PTY and this thread with the
// reader `pty/terminal.odin` already runs; `sh_run` and `sh_pump` are the two calls that
// survive that swap, because the chain only ever asked for "send this out" and "tell me the
// exit code".

// The frame loop's waker, called from the worker thread. Main points it at glfw; a test leaves
// it inert and pumps by hand.
wake := proc() {}

Job :: struct {
    worker: ^thread.Thread,
    // The allocator `out` is built with. A thread gets a fresh context, so without this the
    // output is allocated on the worker and freed on the main thread — two different arenas.
    alloc:  runtime.Allocator,
    cmd:    string, // owned
    feed:   string, // owned; the step's stdin
    fed:    bool,
    lock:   sync.Mutex,
    child:  os.Process, // under the lock: what a quit mid-step has to kill
    spawned: bool,
    out:    string, // owned; written under the lock, read once done
    code:   int,
    done:   bool, // atomic: the one field read without the lock
    live:   bool,
}

// Send a step out. Its stdin is what the step before it piped, staged through a temporary file
// rather than a pipe: nothing reads a stdin pipe until the child runs, so a feed larger than
// one pipe buffer would block us before the child that drains it even exists.
sh_run :: proc(a: ^App, cmd, feed: string, fed: bool) -> bool {
    if a.job.live {
        message_set(a, "a shell step is still running")
        return false
    }
    a.job = Job {
        alloc = context.allocator,
        cmd  = strings.clone(cmd),
        feed = fed ? strings.clone(feed) : "",
        fed  = fed,
        live = true,
    }
    a.job.worker = thread.create(job_proc)
    if a.job.worker == nil {
        job_end(a)
        message_set(a, "could not start a shell step")
        return false
    }
    a.job.worker.data = &a.job
    sys_print(a, fmt.tprintf("$ %s\n", cmd))
    thread.start(a.job.worker)
    return true
}

// After the frame's drains: a finished step's output into N#, and its exit code to the chain.
sh_pump :: proc(a: ^App) {
    if !a.job.live || !sync.atomic_load(&a.job.done) {
        return
    }
    thread.join(a.job.worker)
    thread.destroy(a.job.worker)
    out, code := a.job.out, a.job.code
    a.job.out = "" // the text is handed on below, so job_end must not free it
    defer delete(out)
    job_end(a)

    sys_print(a, out)
    chain_feed(a, out)
    if code != 0 { // §11: a failure surfaces N#
        ring_show_system(a)
    }
    cl_job_done(a, code)
}

// Everything the job owned, and the struct back to rest. The chain is not touched: a caller
// mid-`cl_job_done` is the one who decides what happens next.
@(private = "file")
job_end :: proc(a: ^App) {
    delete(a.job.cmd)
    delete(a.job.feed)
    delete(a.job.out)
    a.job = {}
}

// A quit mid-step kills the child rather than waiting on it: `sleep 100` must not hold the
// window open. Killing it ends the read below, which ends the thread.
job_destroy :: proc(a: ^App) {
    if a.job.live && a.job.worker != nil {
        sync.mutex_lock(&a.job.lock)
        if a.job.spawned {
            _ = os.process_kill(a.job.child)
        }
        sync.mutex_unlock(&a.job.lock)
        thread.join(a.job.worker)
        thread.destroy(a.job.worker)
    }
    job_end(a)
}

@(private = "file")
job_proc :: proc(w: ^thread.Thread) {
    j := (^Job)(w.data)
    out, code := job_exec(j)
    sync.mutex_lock(&j.lock)
    j.out, j.code = out, code
    sync.mutex_unlock(&j.lock)
    sync.atomic_store(&j.done, true)
    wake()
}

// One `sh -c`, run to its exit code. stderr shares stdout's pipe, so the two arrive in the
// order they were written and there is only one pipe to drain — draining two without a poll is
// how a child that fills one while we read the other deadlocks.
@(private = "file")
job_exec :: proc(j: ^Job) -> (string, int) {
    r, w, perr := os.pipe()
    if perr != nil {
        return fmt.aprintf("oket: cannot open a pipe: %v\n", perr, allocator = j.alloc), 1
    }
    d := os.Process_Desc {
        command = {"sh", "-c", j.cmd},
        stdout  = w,
        stderr  = w,
    }
    in_path := ""
    if j.fed {
        f, err := os.create_temp_file("", "oket-feed-*")
        if err != nil {
            os.close(r)
            os.close(w)
            return fmt.aprintf("oket: cannot stage the input: %v\n", err, allocator = j.alloc), 1
        }
        in_path = strings.clone(os.name(f))
        os.write(f, transmute([]u8)j.feed)
        os.seek(f, 0, .Start)
        d.stdin = f
    }

    child, err := os.process_start(d)
    os.close(w) // our copy of the write end, or the read below never sees EOF
    if d.stdin != nil {
        os.close(d.stdin)
        os.remove(in_path)
    }
    delete(in_path)
    if err != nil {
        os.close(r)
        return fmt.aprintf("oket: %s: %v\n", j.cmd, err, allocator = j.alloc), 1
    }
    sync.mutex_lock(&j.lock)
    j.child, j.spawned = child, true
    sync.mutex_unlock(&j.lock)

    // Drained to EOF before the wait: the child can never block on a full pipe, so a command
    // with more output than one pipe buffer finishes rather than wedging.
    out := strings.builder_make(j.alloc)
    buf: [4096]u8
    for {
        n, rerr := os.read(r, buf[:])
        if n > 0 {
            strings.write_bytes(&out, buf[:n])
        }
        if n <= 0 || rerr != nil {
            break
        }
    }
    os.close(r)
    state, werr := os.process_wait(child)
    if werr != nil {
        return strings.to_string(out), 1
    }
    return strings.to_string(out), state.exit_code
}

// --- N# ---

// The system session's document, opened the first time anything needs it. A transcript: no line
// numbers, and it selects by character so a line of output copies out of it.
sys_slot :: proc(a: ^App) -> ^Slot {
    if a.ring.system.live {
        return &a.ring.system
    }
    id := store.store_open(&a.docs, "")
    gen, _ := store.store_gen(&a.docs, id)
    d := desc.new_from({ctx = .Text, selection = .Char, tab_width = 8})
    store.store_submit(&a.docs, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&a.docs)
    a.ring.system = Slot{id, {}, true}
    return &a.ring.system
}

// Append, and keep the tail in view — `follow: tail` is what this becomes once the descriptor
// carries it (§5, §11).
sys_print :: proc(a: ^App, text: string) {
    if text == "" {
        return
    }
    s := sys_slot(a)
    doc := store.store_doc(&a.docs, s.doc)
    if doc == nil {
        return
    }
    txt.doc_cursor_to_end(doc)
    txt.doc_insert_text(doc, text)
    txt.doc_cursor_to_end(doc)
    s.view.point = doc.cursors[doc.primary]
    view.follow(&s.view, max(a.body.h, 1))
}

sys_println :: proc(a: ^App, line: string) {
    sys_print(a, fmt.tprintf("%s\n", line))
}

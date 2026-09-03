package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import "../work"

// §9's I/O workers, driven straight: a subprocess and a watched path, both answered on the
// caller's own thread at a drain it asks for. This is the kernel half of stage 12's gate — the
// plugin half is lsp_test.odin, which reaches the same pool through the seam.

// Drains until `done` says the test has what it came for, or the deadline passes. Everything a
// job says is accumulated, because a child's output arrives in as many pieces as the pipe felt
// like giving.
@(private = "file")
Heard :: struct {
    bytes: [dynamic]u8,
    code:  i32,
    ended: bool,
}

@(private = "file")
settle :: proc(p: ^work.Pool, h: ^Heard, done: proc(_: ^Heard) -> bool, secs := 5) -> bool {
    for _ in 0 ..< secs * 200 {
        for m in work.pool_drain(p) {
            append(&h.bytes, ..m.bytes)
            if m.ended {
                h.ended, h.code = true, m.code
            }
        }
        if done(h) {
            return true
        }
        time.sleep(5 * time.Millisecond)
    }
    return false
}

@(private = "file")
heard_destroy :: proc(h: ^Heard) {
    delete(h.bytes)
}

@(test)
a_child_writes_and_exits :: proc(t: ^testing.T) {
    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    _, ok := work.pool_spawn(&p, {"sh", "-c", "printf hello; exit 3"})
    testing.expect(t, ok, "sh did not spawn")

    h: Heard
    defer heard_destroy(&h)
    testing.expect(t, settle(&p, &h, proc(h: ^Heard) -> bool {return h.ended}),
                   "the child never ended")
    testing.expect_value(t, string(h.bytes[:]), "hello")
    testing.expect_value(t, h.code, 3)
}

// A clean exit is a zero — the status core's Linux WIFSIGNALED misreads as a signal.
@(test)
a_clean_exit_is_code_zero :: proc(t: ^testing.T) {
    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    _, ok := work.pool_spawn(&p, {"sh", "-c", "exit 0"})
    testing.expect(t, ok, "sh did not spawn")
    h: Heard
    defer heard_destroy(&h)
    testing.expect(t, settle(&p, &h, proc(h: ^Heard) -> bool {return h.ended}),
                   "the child never ended")
    testing.expect_value(t, h.code, 0)
}

// The round trip stage 12 is really about: bytes down, an answer back, and the frame loop free
// the whole time. `read` blocks in the CHILD, which is the point — nothing here does.
@(test)
a_child_answers_what_was_written :: proc(t: ^testing.T) {
    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    id, ok := work.pool_spawn(&p, {"sh", "-c", "read line; printf 'got %s' \"$line\""})
    testing.expect(t, ok, "sh did not spawn")
    testing.expect(t, work.pool_write(&p, id, transmute([]u8)string("ping\n")))

    h: Heard
    defer heard_destroy(&h)
    testing.expect(t, settle(&p, &h, proc(h: ^Heard) -> bool {return h.ended}),
                   "the child never answered")
    testing.expect_value(t, string(h.bytes[:]), "got ping")
}

// A job that ended leaves a dead Id, not a reusable one.
@(test)
a_handle_past_its_job_is_refused :: proc(t: ^testing.T) {
    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    id, _ := work.pool_spawn(&p, {"sh", "-c", "exit 0"})
    h: Heard
    defer heard_destroy(&h)
    testing.expect(t, settle(&p, &h, proc(h: ^Heard) -> bool {return h.ended}),
                   "the child never ended")
    testing.expect(t, !work.pool_live(&p, id), "a job that ended still reads as live")
    testing.expect(t, !work.pool_write(&p, id, transmute([]u8)string("x")),
                   "a dead handle still took a write")
}

// Closing is silent: a job the holder ended is not one it needs telling about.
@(test)
a_closed_job_says_nothing :: proc(t: ^testing.T) {
    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    id, ok := work.pool_spawn(&p, {"sh", "-c", "printf a; sleep 30"})
    testing.expect(t, ok, "sh did not spawn")
    work.pool_close(&p, id)

    h: Heard
    defer heard_destroy(&h)
    settle(&p, &h, proc(h: ^Heard) -> bool {return false}, 1)
    testing.expect(t, !h.ended, "a closed job reported an end")
    testing.expect(t, !work.pool_live(&p, id), "a closed job still reads as live")
}

// A spawn that cannot start is refused AT THE CALL: a zero answer, not a completion nobody
// can correlate.
@(test)
a_command_nowhere_on_path_is_refused :: proc(t: ^testing.T) {
    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    _, ok := work.pool_spawn(&p, {"oket-no-such-command"})
    testing.expect(t, !ok, "a command PATH does not hold still spawned")
}

// Past the fork the refusal has to be a completion, and it is a shell's: exec failed is 127.
@(test)
an_exec_that_fails_is_exit_127 :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-noexec")
    if !made {
        return
    }
    plain, _ := filepath.join({dir, "plain.txt"}, context.temp_allocator)
    _ = os.write_entire_file(plain, transmute([]u8)string("not a program"))

    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    _, ok := work.pool_spawn(&p, {plain})
    testing.expect(t, ok, "a plain file did not even fork")
    h: Heard
    defer heard_destroy(&h)
    testing.expect(t, settle(&p, &h, proc(h: ^Heard) -> bool {return h.ended}),
                   "the failed exec never ended")
    testing.expect_value(t, h.code, 127)
}

// The other half of §9's list. The DIRECTORY is what inotify holds, so the answer survives the
// save-by-rename every editor does — which is what the third write here is.
@(test)
a_watch_names_the_file_that_changed :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-watch")
    if !made {
        return
    }
    path, _ := filepath.join({dir, "alpha.txt"}, context.temp_allocator)

    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    _, ok := work.pool_watch(&p, path)
    testing.expect(t, ok, "the path is not watched")

    h: Heard
    defer heard_destroy(&h)
    _ = os.write_entire_file(path, transmute([]u8)string("changed"))
    testing.expect(t, settle(&p, &h, proc(h: ^Heard) -> bool {return len(h.bytes) > 0}),
                   "the write was not reported")
    testing.expect_value(t, string(h.bytes[:]), path)

    // Written somewhere else and moved on top, which is what a watch on the FILE would miss.
    clear(&h.bytes)
    tmp, _ := filepath.join({dir, "alpha.new"}, context.temp_allocator)
    _ = os.write_entire_file(tmp, transmute([]u8)string("renamed"))
    _ = os.rename(tmp, path)
    testing.expect(t, settle(&p, &h, proc(h: ^Heard) -> bool {return len(h.bytes) > 0}),
                   "a save by rename was not reported")
    testing.expect_value(t, string(h.bytes[:]), path)
}

// A watch on a directory two jobs share: one inotify watch descriptor, two answers, and the
// name is what tells them apart.
@(test)
two_watches_on_one_directory_stay_apart :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-watch-pair")
    if !made {
        return
    }
    alpha, _ := filepath.join({dir, "alpha.txt"}, context.temp_allocator)
    beta, _ := filepath.join({dir, "beta.txt"}, context.temp_allocator)

    p: work.Pool
    testing.expect(t, work.pool_start(&p))
    defer work.pool_stop(&p)

    a_id, _ := work.pool_watch(&p, alpha)
    b_id, _ := work.pool_watch(&p, beta)
    testing.expect(t, a_id != b_id, "two watches took one slot")

    _ = os.write_entire_file(beta, transmute([]u8)string("changed"))
    said := make(map[work.Id]string, context.temp_allocator)
    for _ in 0 ..< 1000 {
        for m in work.pool_drain(&p) {
            said[m.id] = string(m.bytes)
        }
        if len(said) > 0 {
            break
        }
        time.sleep(5 * time.Millisecond)
    }
    testing.expect_value(t, len(said), 1)
    testing.expect_value(t, said[b_id], beta)
}

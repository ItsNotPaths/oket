package work

import "base:runtime"
import "core:c"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "../wake"

// Kernel-owned I/O workers (§9). A subprocess and a file watch are the two slow things a
// plugin cannot do on the main thread and must not do on one of its own, so the kernel does
// both on ONE thread and hands the results over as data.
//
// The thread does nothing but wait: `poll` over every child's pipes and one inotify fd. The
// main thread spawns, writes, closes and drains — and never touches a file descriptor. That
// last rule is not a style choice: an fd the main thread closes while the worker is parked in
// `poll` can be reopened as somebody else's the moment a spawn reuses the number. So `pool_close`
// only ASKS, and the worker is the only place a descriptor dies.
//
// Everything crosses at `pool_drain`, once a frame, which is where every other write in this
// system already lands (§6).
//
// A slot is tombstoned and its `seq` bumped, so an Id kept past the end of a job resolves to
// nothing rather than to whoever spawned next — the same rule store.Id and plug.Self follow.
//
// A POOL MUST NOT MOVE once it is started: the worker holds this pointer for its whole life. A
// caller that keeps its state in something copied by value holds the pool behind a pointer for
// that reason, which is what src/oket/io.odin does.

// Unread bytes per job before the reader stops asking for more. Past this the pipe's own buffer
// is the back-pressure and the child blocks, which is the correct answer to a plugin that is
// not reading: nothing is dropped and nothing grows without a bound.
CAP :: 4 << 20

Id :: struct {
    slot: u32,
    seq:  u32,
}

Kind :: enum u8 {
    Proc,
    Watch,
}

// What one drain hands over for one job. `bytes` is temp-allocated by the drain and `ended`
// says the job is over — both can be true at once, which is a child that wrote and exited
// between two frames.
Msg :: struct {
    id:    Id,
    bytes: []u8,
    code:  i32,
    ended: bool,
}

@(private)
Job :: struct {
    id:      Id,
    kind:    Kind,
    live:    bool,
    closing: bool, // the main thread asked; the worker does the closing
    ended:   bool, // the child was reaped, and `code` is what it said
    code:    i32,

    // Proc. `into` is the child's stdin, `out` its stdout; its stderr is inherited (see
    // pool_spawn).
    pid:     posix.pid_t,
    out:     posix.FD,
    into:    posix.FD,

    // Watch. The DIRECTORY is what inotify holds, because an editor that saves by rename
    // leaves a watch on the file pointing at an inode nobody will write again.
    wd:      linux.Wd,
    dir:     string, // owned
    base:    string, // owned
    hit:     bool,

    to_child: [dynamic]u8,
    from:     [dynamic]u8,
}

Pool :: struct {
    lock:     sync.Mutex,
    // ONE allocator, the process heap: a job's buffers are filled on the worker and freed
    // on the main thread, so it must be thread-safe — a per-test tracking allocator is not.
    alloc:    mem.Allocator,
    jobs:     [dynamic]Job,
    seq:      u32,
    ino:      linux.Fd,
    wake_r:   posix.FD,
    wake_w:   posix.FD,
    worker:   ^thread.Thread,
    stopping: bool,
    started:  bool,
}

pool_start :: proc(p: ^Pool) -> bool {
    if p.started {
        return true
    }
    p.alloc = runtime.default_allocator()
    // A write to a child that has exited is EPIPE here and a dead editor without it.
    sync.once_do(&sigpipe_once, proc() {
        act: posix.sigaction_t
        act.sa_handler = auto_cast posix.SIG_IGN
        posix.sigemptyset(&act.sa_mask)
        posix.sigaction(.SIGPIPE, &act, nil)
    })
    ino, ierr := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
    if ierr != .NONE {
        return false
    }
    fds: [2]posix.FD
    if posix.pipe(&fds) != .OK {
        linux.close(ino)
        return false
    }
    p.ino, p.wake_r, p.wake_w = ino, fds[0], fds[1]
    nonblock(p.wake_r)
    nonblock(p.wake_w)
    p.worker = thread.create(worker_proc)
    if p.worker == nil {
        linux.close(ino)
        posix.close(p.wake_r)
        posix.close(p.wake_w)
        return false
    }
    p.started = true
    p.worker.data = p
    thread.start(p.worker)
    return true
}

// Every job torn down by the worker, then the worker joined. Safe on a pool that never started.
pool_stop :: proc(p: ^Pool) {
    if !p.started {
        delete(p.jobs)
        p.jobs = nil
        return
    }
    context.allocator = p.alloc
    sync.mutex_lock(&p.lock)
    for i in 0 ..< len(p.jobs) {
        p.jobs[i].closing = true
    }
    sync.atomic_store(&p.stopping, true)
    sync.mutex_unlock(&p.lock)
    poke(p)
    thread.join(p.worker)
    thread.destroy(p.worker)
    p.worker = nil
    linux.close(p.ino)
    posix.close(p.wake_r)
    posix.close(p.wake_w)
    delete(p.jobs)
    p.jobs = nil
    p.started = false
}

// A child, with pipes on its stdin and stdout. Its STDERR IS INHERITED: merging it into stdout
// would corrupt a framed protocol, and capturing it needs a third stream on the seam for
// something a shell redirect already answers (§7).
//
// The exec path is resolved HERE, before the fork: a PATH search allocates, and a child of a
// multithreaded process may not (pty/terminal.odin's rule).
pool_spawn :: proc(p: ^Pool, argv: []string, cwd := "") -> (Id, bool) {
    if !p.started || len(argv) == 0 {
        return {}, false
    }
    context.allocator = p.alloc
    exe, found := exe_path(argv[0])
    if !found {
        return {}, false
    }
    defer delete(exe)

    // Everything the child touches, built pre-fork.
    cargv := make([]cstring, len(argv) + 1)
    for arg, i in argv {
        cargv[i] = strings.clone_to_cstring(arg)
    }
    cexe := strings.clone_to_cstring(exe)
    cdir := cwd == "" ? cstring(nil) : strings.clone_to_cstring(cwd)
    defer {
        for s in cargv {
            delete(s)
        }
        delete(cargv)
        delete(cexe)
        delete(cdir)
    }

    // CLOEXEC, and it is not tidiness: two spawns can overlap, and a pipe without it is
    // inherited by the OTHER child, which then holds a write end open and nobody ever sees EOF.
    // `dup2` clears the flag, so the two the child keeps are the two it was given.
    in_pipe, out_pipe: [2]linux.Fd
    if linux.pipe2(&in_pipe, {.CLOEXEC}) != .NONE {
        return {}, false
    }
    if linux.pipe2(&out_pipe, {.CLOEXEC}) != .NONE {
        linux.close(in_pipe[0])
        linux.close(in_pipe[1])
        return {}, false
    }
    in_fds := [2]posix.FD{posix.FD(in_pipe[0]), posix.FD(in_pipe[1])}
    out_fds := [2]posix.FD{posix.FD(out_pipe[0]), posix.FD(out_pipe[1])}
    pid := posix.fork()
    if pid < 0 {
        for fd in ([?]posix.FD{in_fds[0], in_fds[1], out_fds[0], out_fds[1]}) {
            posix.close(fd)
        }
        return {}, false
    }
    if pid == 0 {
        // CHILD — pre-allocated cstrings only, ending in exec.
        if cdir != nil {
            posix.chdir(cdir) // best effort
        }
        posix.setsid() // its own group, so a close kills the tree and not just the head
        posix.dup2(in_fds[0], posix.STDIN_FILENO)
        posix.dup2(out_fds[1], posix.STDOUT_FILENO)
        for fd in ([?]posix.FD{in_fds[0], in_fds[1], out_fds[0], out_fds[1]}) {
            if fd > posix.STDERR_FILENO {
                posix.close(fd)
            }
        }
        posix.execv(cexe, raw_data(cargv))
        posix._exit(127) // exec failed
    }
    posix.close(in_fds[0])
    posix.close(out_fds[1])
    nonblock(in_fds[1])
    nonblock(out_fds[0])

    sync.mutex_lock(&p.lock)
    j := job_take(p)
    j.kind = .Proc
    j.pid = pid
    j.into = in_fds[1]
    j.out = out_fds[0]
    id := j.id
    sync.mutex_unlock(&p.lock)
    poke(p)
    return id, true
}

// A path, watched through its DIRECTORY and filtered by name: `mv tmp file` is how most
// programs write a file, and it leaves a watch on the file itself holding the old inode.
pool_watch :: proc(p: ^Pool, path: string) -> (Id, bool) {
    if !p.started || path == "" {
        return {}, false
    }
    context.allocator = p.alloc
    full, _ := filepath.abs(path, context.temp_allocator)
    if full == "" {
        full = path
    }
    dir, base := filepath.dir(full), filepath.base(full)
    cdir := strings.clone_to_cstring(dir, context.temp_allocator)
    // The directory, not the file: CREATE and MOVED_TO are how the file comes BACK.
    wd, err := linux.inotify_add_watch(p.ino, cdir,
                                       {.CLOSE_WRITE, .MOVED_TO, .CREATE, .DELETE, .MOVED_FROM})
    if err != .NONE {
        return {}, false
    }
    sync.mutex_lock(&p.lock)
    j := job_take(p)
    j.kind = .Watch
    j.wd = wd
    j.dir = strings.clone(dir)
    j.base = strings.clone(base)
    id := j.id
    sync.mutex_unlock(&p.lock)
    return id, true
}

// Queued, never written here: a full pipe would block the frame, which is the whole thing this
// package exists to stop.
pool_write :: proc(p: ^Pool, id: Id, bytes: []u8) -> bool {
    if !p.started || len(bytes) == 0 {
        return false
    }
    context.allocator = p.alloc
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    j := job_at(p, id)
    if j == nil || j.kind != .Proc || j.into < 0 {
        return false
    }
    append(&j.to_child, ..bytes)
    poke(p)
    return true
}

// Asks. The worker kills the child, closes the descriptors and frees the slot, and nothing is
// reported: a job the holder ended is not one it needs telling about.
pool_close :: proc(p: ^Pool, id: Id) {
    if !p.started {
        return
    }
    sync.mutex_lock(&p.lock)
    if j := job_at(p, id); j != nil {
        j.closing = true
        poke(p)
    }
    sync.mutex_unlock(&p.lock)
}

pool_live :: proc(p: ^Pool, id: Id) -> bool {
    if !p.started {
        return false
    }
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    j := job_at(p, id)
    return j != nil && !j.closing
}

// The one crossing point (§6). Everything a job has to say since the last frame, in one message
// per job, and a job that ENDED leaves its slot here — the drain is the last reader, so freeing
// it anywhere else would be freeing what somebody is about to read.
pool_drain :: proc(p: ^Pool, alloc := context.temp_allocator) -> []Msg {
    if !p.started {
        return nil
    }
    out := make([dynamic]Msg, 0, 4, alloc)
    context.allocator = p.alloc // the buffers being freed below are the worker's
    blocked := false
    sync.mutex_lock(&p.lock)
    for i in 0 ..< len(p.jobs) {
        j := &p.jobs[i]
        if !j.live || j.closing {
            continue
        }
        if len(j.from) == 0 && !j.hit && !j.ended {
            continue
        }
        m := Msg{id = j.id, code = j.code, ended = j.ended}
        if len(j.from) > 0 {
            m.bytes = slice.clone(j.from[:], alloc)
            blocked ||= len(j.from) >= CAP
            clear(&j.from)
        } else if j.hit {
            m.bytes = transmute([]u8)strings.concatenate({j.dir, "/", j.base}, alloc)
        }
        j.hit = false
        append(&out, m)
        if j.ended {
            job_free(j)
        }
    }
    sync.mutex_unlock(&p.lock)
    if blocked {
        // A job at CAP left the poll set, and this drain emptied it: the worker must re-arm.
        poke(p)
    }
    return out[:]
}

// --- the worker ---

@(private = "file")
sigpipe_once: sync.Once

@(private = "file")
worker_proc :: proc(th: ^thread.Thread) {
    p := (^Pool)(th.data)
    // Its OWN context: inheriting the creator's temp-allocator arena would share it across
    // threads.
    context = runtime.default_context()
    context.allocator = p.alloc
    fds := make([dynamic]posix.pollfd)
    owners := make([dynamic]int) // fds[i] belongs to jobs[owners[i]]; -1 for the two fixed ones
    defer {
        delete(fds)
        delete(owners)
    }
    for !sync.atomic_load(&p.stopping) {
        waiting := worker_arm(p, &fds, &owners)
        // A child that closed stdout but has not exited yet is the one case with nothing to
        // wait ON, so that is the only case that polls on a timer.
        n := posix.poll(raw_data(fds), posix.nfds_t(len(fds)), waiting ? 20 : -1)
        if n < 0 {
            if posix.errno() == .EINTR {
                continue
            }
            break
        }
        if .IN in fds[0].revents {
            drink(p.wake_r)
        }
        if .IN in fds[1].revents {
            worker_inotify(p)
        }
        if worker_pump(p, fds[:], owners[:]) {
            wake.hook()
        }
    }
    sync.mutex_lock(&p.lock)
    for i in 0 ..< len(p.jobs) {
        job_tear_down(&p.jobs[i])
    }
    sync.mutex_unlock(&p.lock)
}

// The poll set for this pass: the two fixed fds, then every pipe worth waiting on. Closing
// jobs are torn down here, on the worker. True when a child with a closed stdout still owes
// an exit code — the one thing with no fd to wait on.
@(private = "file")
worker_arm :: proc(p: ^Pool, fds: ^[dynamic]posix.pollfd, owners: ^[dynamic]int) -> bool {
    clear(fds)
    clear(owners)
    append(fds, posix.pollfd{fd = p.wake_r, events = {.IN}})
    append(fds, posix.pollfd{fd = posix.FD(p.ino), events = {.IN}})
    append(owners, -1, -1)

    waiting := false
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    for i in 0 ..< len(p.jobs) {
        j := &p.jobs[i]
        if !j.live {
            continue
        }
        if j.closing {
            job_tear_down(j)
            continue
        }
        if j.kind != .Proc {
            continue
        }
        // Not asking for bytes we have nowhere to put is the back-pressure: the pipe
        // fills, and the child waits rather than the memory growing.
        if j.out >= 0 && len(j.from) < CAP {
            append(fds, posix.pollfd{fd = j.out, events = {.IN}})
            append(owners, i)
        }
        if j.into >= 0 && len(j.to_child) > 0 {
            append(fds, posix.pollfd{fd = j.into, events = {.OUT}})
            append(owners, i)
        }
        waiting ||= j.out < 0 && !j.ended
    }
    return waiting
}

// What the poll said, acted on: reads, writes, then reaps. True when a plugin should be told.
@(private = "file")
worker_pump :: proc(p: ^Pool, fds: []posix.pollfd, owners: []int) -> bool {
    told := false
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    for pfd, i in fds[2:] {
        j := &p.jobs[owners[i + 2]]
        if !j.live || j.closing {
            continue
        }
        if pfd.fd == j.out && pfd.revents != {} {
            told = worker_read(j) || told
        } else if pfd.fd == j.into && .OUT in pfd.revents {
            worker_send(j)
        }
    }
    for i in 0 ..< len(p.jobs) {
        j := &p.jobs[i]
        if j.live && !j.closing && j.kind == .Proc && j.out < 0 && !j.ended {
            told = worker_reap(j) || told
        }
    }
    return told
}

// Under the pool lock. False when there was nothing new to say.
@(private = "file")
worker_read :: proc(j: ^Job) -> bool {
    buf: [16 * 1024]u8
    for {
        n := posix.read(j.out, raw_data(buf[:]), len(buf))
        if n > 0 {
            append(&j.from, ..buf[:n])
            if len(j.from) >= CAP {
                return true
            }
            continue
        }
        if n < 0 {
            err := posix.errno()
            if err == .EINTR {
                continue
            }
            if err == .EAGAIN || err == .EWOULDBLOCK {
                return len(j.from) > 0
            }
        }
        // EOF or a real error: the write end is gone everywhere, so only the status is left.
        posix.close(j.out)
        j.out = -1
        return true
    }
}

@(private = "file")
worker_send :: proc(j: ^Job) {
    for len(j.to_child) > 0 {
        n := posix.write(j.into, raw_data(j.to_child), c.size_t(len(j.to_child)))
        if n > 0 {
            remove_range(&j.to_child, 0, int(n))
            continue
        }
        if n < 0 && posix.errno() == .EINTR {
            continue
        }
        if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK) {
            return // the pipe is full; the next POLLOUT takes the rest
        }
        // The child is not reading and never will be. Drop what is queued rather than carry
        // it forever: the exit code is what the holder is waiting for now.
        posix.close(j.into)
        j.into = -1
        clear(&j.to_child)
        return
    }
}

@(private = "file")
worker_reap :: proc(j: ^Job) -> bool {
    status: c.int
    if posix.waitpid(j.pid, &status, {.NOHANG}) != j.pid {
        return false // still going; the 20 ms timeout above brings us back
    }
    // Exited asked FIRST: core's Linux WIFSIGNALED compares signed, so a clean exit 0
    // reads as "killed by signal 0" and a 0 becomes a 128.
    if posix.WIFEXITED(status) {
        j.code = i32(posix.WEXITSTATUS(status))
    } else {
        j.code = 128 + i32(posix.WTERMSIG(status))
    }
    j.pid = 0
    if j.into >= 0 {
        posix.close(j.into)
        j.into = -1
    }
    j.ended = true
    return true
}

// One read of the inotify fd, and every event in it matched against the watches. Two jobs
// watching one directory share a `wd`, so this matches ALL of them and filters by name.
@(private = "file")
worker_inotify :: proc(p: ^Pool) {
    buf: [8 * 1024]u8
    told := false
    for {
        n, err := linux.read(p.ino, buf[:])
        if n <= 0 {
            if err == .EINTR {
                continue
            }
            break
        }
        sync.mutex_lock(&p.lock)
        for off := 0; off + size_of(linux.Inotify_Event) <= int(n); {
            ev := (^linux.Inotify_Event)(&buf[off])
            name := ""
            if ev.len > 0 {
                raw := buf[off + size_of(linux.Inotify_Event):][:ev.len]
                name = string(cstring(raw_data(raw)))
            }
            for i in 0 ..< len(p.jobs) {
                j := &p.jobs[i]
                if j.live && !j.closing && j.kind == .Watch && j.wd == ev.wd && j.base == name {
                    j.hit = true
                    told = true
                }
            }
            off += size_of(linux.Inotify_Event) + int(ev.len)
        }
        sync.mutex_unlock(&p.lock)
        if int(n) < len(buf) {
            break
        }
    }
    if told {
        wake.hook()
    }
}

// --- internals ---

// Under the pool lock, on the worker only. A child gets its GROUP signalled, the same reason
// pty/terminal.odin does it: a killed head can leave a child holding the pipe, and then nothing
// ever sees EOF. A watch is NOT inotify_rm_watch'd: a second job on the same directory shares
// the `wd`, and removing it would blind the other one.
@(private = "file")
job_tear_down :: proc(j: ^Job) {
    if j.pid > 0 {
        posix.kill(-j.pid, .SIGTERM)
        status: c.int
        for _ in 0 ..< 20 {
            if posix.waitpid(j.pid, &status, {.NOHANG}) == j.pid {
                j.pid = 0
                break
            }
            time.sleep(5 * time.Millisecond)
        }
        if j.pid > 0 {
            posix.kill(-j.pid, .SIGKILL)
            posix.waitpid(j.pid, &status, {})
            j.pid = 0
        }
    }
    for fd in ([?]^posix.FD{&j.out, &j.into}) {
        if fd^ >= 0 {
            posix.close(fd^)
            fd^ = -1
        }
    }
    job_free(j)
}

// The slot back to rest, with its seq already bumped by job_take: an Id from the job that just
// ended resolves to nothing.
@(private = "file")
job_free :: proc(j: ^Job) {
    delete(j.dir)
    delete(j.base)
    delete(j.to_child)
    delete(j.from)
    j^ = Job{id = j.id, out = -1, into = -1}
}

@(private = "file")
job_take :: proc(p: ^Pool) -> ^Job {
    for i in 0 ..< len(p.jobs) {
        if !p.jobs[i].live {
            p.seq += 1
            p.jobs[i] = Job{id = {u32(i), p.seq}, live = true, out = -1, into = -1}
            return &p.jobs[i]
        }
    }
    p.seq += 1
    append(&p.jobs, Job{id = {u32(len(p.jobs)), p.seq}, live = true, out = -1, into = -1})
    return &p.jobs[len(p.jobs) - 1]
}

@(private = "file")
job_at :: proc(p: ^Pool, id: Id) -> ^Job {
    if int(id.slot) >= len(p.jobs) {
        return nil
    }
    j := &p.jobs[id.slot]
    return j.live && j.id.seq == id.seq ? j : nil
}

// One byte down the pipe: the worker is parked in `poll` and this is what ends the wait.
@(private = "file")
poke :: proc(p: ^Pool) {
    b: [1]u8
    posix.write(p.wake_w, raw_data(b[:]), 1)
}

@(private = "file")
drink :: proc(fd: posix.FD) {
    buf: [256]u8
    for posix.read(fd, raw_data(buf[:]), len(buf)) == len(buf) {}
}

@(private = "file")
nonblock :: proc(fd: posix.FD) {
    flags := posix.fcntl(fd, .GETFL)
    posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
}

// argv[0] resolved to something `execv` takes without searching. A name with a slash in it is
// already a path; anything else walks $PATH here, on the main thread, where allocating is legal.
@(private = "file")
exe_path :: proc(name: string) -> (string, bool) {
    if strings.contains(name, "/") {
        return strings.clone(name), os.is_file(name)
    }
    path := os.get_env("PATH", context.temp_allocator)
    for dir in strings.split_iterator(&path, ":") {
        if dir == "" {
            continue
        }
        full, _ := filepath.join({dir, name}, context.temp_allocator)
        if os.is_file(full) {
            return strings.clone(full), true
        }
    }
    return "", false
}

package main

import "../plug"
import "../store"
import "../work"

// The plugin side of §9's I/O workers. `work` owns the thread and the descriptors; this file
// owns who asked, where the answer goes, and when it is handed over.
//
// WHEN is the whole point: a completion is delivered at one place in the frame, on the main
// thread, through the `event` message that already exists. A plugin submits work and is told
// the answer; it never sees a thread, and the kernel never grows a seventh message for it.
//
// The routing rule is the one `.Moved` already uses. A job names a document at spawn:
//
//     the caller's own instance   -> that kind's `event`, with `inst` filled
//     anything else, or no doc    -> the caller's watcher, if it registered one
//     neither                     -> dropped, and the job is closed
//
// The pool starts on the first job and not before, so a session that spawns nothing runs the
// thread count it always did.

// Who a job belongs to and where its answers go. The plugin index and not a `Self`: a plugin
// that reloads is a new generation, and the old one's jobs die with it in plug_unload.
Io_Job :: struct {
    owner: int,
    doc:   store.Id,
}

io_destroy :: proc(a: ^App) {
    if a.io != nil {
        work.pool_stop(a.io)
        free(a.io)
        a.io = nil
    }
    delete(a.io_jobs)
    a.io_jobs = nil // a plugin closing under app_destroy still looks a job up in here
}

// Everything the workers have to say, once a frame, before the moved pass reads the documents
// an I/O handler may have written (main.odin). A job that ENDED is forgotten here: its Id is
// dead in the pool already, so keeping the record would only make the map grow.
io_pump :: proc(a: ^App) {
    if a.io == nil {
        return
    }
    for m in work.pool_drain(a.io) {
        job, held := a.io_jobs[m.id]
        if !held {
            continue
        }
        if len(m.bytes) > 0 {
            io_deliver(a, job, m.id, .Io, m.bytes, 0)
        }
        // Asked again, because the handler above may have closed this very job — and a job the
        // holder ended is not one it is told about.
        if _, still := a.io_jobs[m.id]; still && m.ended {
            io_deliver(a, job, m.id, .Io_End, nil, m.code)
            delete_key(&a.io_jobs, m.id)
        }
    }
}

// Every job a plugin owns, ended. Called from plug_unload, so a plugin that dies takes its
// children with it rather than leaving a subprocess with nobody to read it.
io_forget :: proc(a: ^App, owner: int) {
    if a.io == nil {
        return
    }
    dead := make([dynamic]work.Id, 0, len(a.io_jobs), context.temp_allocator)
    for id, job in a.io_jobs {
        if job.owner == owner {
            append(&dead, id)
        }
    }
    for id in dead {
        work.pool_close(a.io, id)
        delete_key(&a.io_jobs, id)
    }
}

// --- the api, as a plugin sees it ---

@(private)
api_io_spawn :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc, argv: [^]cstring,
                          nargv: uint, cwd: [^]u8, cwd_len: uint) -> plug.Io {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok || nargv == 0 {
        return 0
    }
    context = a.api.ctx
    pool := io_pool(a)
    if pool == nil {
        return 0
    }
    words := make([]string, nargv, context.temp_allocator)
    for n in 0 ..< nargv {
        words[n] = string(argv[n])
    }
    return io_start(a, i, doc, work.pool_spawn(pool, words, string(cwd[:cwd_len])))
}

@(private)
api_io_watch :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc, path: [^]u8,
                          path_len: uint) -> plug.Io {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok || path_len == 0 {
        return 0
    }
    context = a.api.ctx
    pool := io_pool(a)
    if pool == nil {
        return 0
    }
    return io_start(a, i, doc, work.pool_watch(pool, string(path[:path_len])))
}

@(private)
api_io_write :: proc "c" (api: ^plug.Api, self: plug.Self, io: plug.Io, bytes: [^]u8,
                          length: uint) {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = a.api.ctx
    id := work_id(io)
    if job, held := a.io_jobs[id]; held && job.owner == i {
        work.pool_write(a.io, id, bytes[:length])
    }
}

@(private)
api_io_close :: proc "c" (api: ^plug.Api, self: plug.Self, io: plug.Io) {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = a.api.ctx
    id := work_id(io)
    if job, held := a.io_jobs[id]; held && job.owner == i {
        work.pool_close(a.io, id)
        delete_key(&a.io_jobs, id)
    }
}

// --- internals ---

// On the HEAP: the worker holds this address for its whole life, and an App is a value.
@(private = "file")
io_pool :: proc(a: ^App) -> ^work.Pool {
    if a.io == nil {
        a.io = new(work.Pool)
        if !work.pool_start(a.io) {
            free(a.io)
            a.io = nil
        }
    }
    return a.io
}

// The pool, started on demand, and the record that says who a job's answers belong to. A spawn
// that failed is a zero handle: the plugin is told at the call rather than through a completion
// nobody can correlate.
@(private = "file")
io_start :: proc(a: ^App, owner: int, doc: plug.Doc, id: work.Id, spawned: bool) -> plug.Io {
    if !spawned {
        return 0
    }
    a.io_jobs[id] = {owner, store_id(doc)}
    return plug_io(id)
}

// One completion, at the handler the routing rule picks. `docs_settle` after it for rule 6's
// reason: a plugin's transaction lands when its CALL returns, and an I/O handler writing a
// document is the ordinary case here, not the exception.
@(private = "file")
io_deliver :: proc(a: ^App, job: Io_Job, id: work.Id, ev: plug.Event, text: []u8, code: i32) {
    at := plug.At{doc = plug_doc(job.doc), io = plug_io(id), code = code}
    call := Plug_Call{what = .Watch, at = &at, ev = ev, data = text}
    if inst, held := a.insts[job.doc]; held && inst.owner == job.owner {
        if k, known := plug_kind(a, inst.kind); known && k.vt.event != nil {
            at.inst = inst.inst
            call.what, call.vt = .Event, k.vt
        }
    } else if a.plugs[job.owner].live {
        call.fn_ev = a.plugs[job.owner].watch
    }
    if call.vt.event == nil && call.fn_ev == nil {
        // Nobody is listening: the document is gone, the kind has no event handler, or there
        // is no watcher. Ended rather than left running with no reader.
        work.pool_close(a.io, id)
        delete_key(&a.io_jobs, id)
        return
    }
    view := view_make(a, job.doc)
    defer view_free(view)
    if view != nil {
        at.snap = &view.snap
    }
    if _, ran := plug_dispatch(a, job.owner, call); ran {
        docs_settle(a)
    }
}

// --- handles ---

plug_io :: proc(id: work.Id) -> plug.Io {
    return plug.Io(u64(id.slot) | u64(id.seq) << 32)
}

work_id :: proc(io: plug.Io) -> work.Id {
    return {u32(u64(io) & 0xffff_ffff), u32(u64(io) >> 32)}
}

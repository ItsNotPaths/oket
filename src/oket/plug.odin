package main

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "../desc"
import "../input"
import "../plug"
import "../store"
import "../txt"

// The plugin seam, kernel side (§7). One tier: `.so`, `dlopen`'d, in-process, trusted. A plugin
// that corrupts memory takes the editor down, and that is the accepted price for the seam being
// six messages instead of forty.
//
// THE LEDGER IS THE WHOLE UNLOAD STORY. Every `register_*` appends a record; unload closes the
// plugin's open documents, walks the ledger backwards, and dlcloses. A `dlclose` that fails to
// unmap costs address space rather than correctness.
//
// Slots are tombstoned, never compacted. An `input.Kind` and an `input.Slot` are indices, and a
// bind row or a descriptor may hold one across a reload — reusing the index would route a
// keystroke into whoever loaded next.

PLUGIN_DIR :: "plugins" // in the data directory: what a release wrote (path.odin)

Plugin :: struct {
    name:    string, // owned; the file's stem, and the section header in binds.conf
    path:    string, // owned
    lib:     dynlib.Library,
    base:    uintptr, // where dlopen mapped it, which is what names a faulting pc (§10)
    gen:     u32, // bumped per load, so a Self from an earlier load is refused
    live:    bool,
    faulted: bool, // it died in its own code; nothing of it is called again (§10)
    ledger:  [dynamic]Record,
    // A plugin that draws nothing asks to be told about documents it did not open (§9). `seen`
    // is what it has been told, per document, so a moved generation is reported once.
    watch:   plug.Event_Fn,
    seen:    map[store.Id]Watch,
    // Its view stage (§5), if it has one. ONE per plugin: the config line that orders the
    // pipeline ranks stages by PLUGIN NAME, the same rule the span store's producers follow.
    viewer:  plug.View_Fn,
}

// What a handler was last told about one document; an instance's owner and a watcher keep the
// same record. `latch` is cooperative slicing: a `.Moved` that answered non-zero is called
// again next frame whether or not anything moved, which is how a cold parse too big for one
// frame spreads over several with no thread (§9).
Watch :: struct {
    gen:   u64,
    // Its own transaction, still waiting on the drain (rule 3). A generation this moved is not
    // reported back, or a plugin that re-reads on `moved` would answer its own write forever.
    // The TAG and not a flag: a submit that loses the race is dropped, and that case is exactly
    // when the holder has to be told.
    tag:   u64,
    latch: bool,
}

Record_Kind :: enum u8 {
    Kind,
    Command,
    Bind,
    Watch,
    View,
    Config,
}

Record :: struct {
    what: Record_Kind,
    idx:  int, // into a.kinds, a.cmds or a.reqs
}

// A kind a plugin registered, appended past the kernel's own (kinds.odin). `owner` goes to -1
// on unload and the name empties: the id stays valid and resolves to nothing.
Plug_Kind :: struct {
    name:  string, // owned
    ctx:   input.Bind_Ctx,
    owner: int,
    vt:    plug.Kind_Vt,
}

// A command past the kernel's core set (§12). `input.Slot` is its index here, which is what a
// bind row holds.
Plug_Cmd :: struct {
    name:  string, // owned
    doc:   string, // owned
    owner: int,
    fn:    plug.Command_Fn,
}

// A document a plugin opened. The instance pointer is the plugin's; the text and the descriptor
// are the kernel's, and anyone may write them (§7).
Plug_Inst :: struct {
    owner:      int,
    kind:       input.Kind,
    inst:       rawptr,
    using told: Watch, // what its owner was last told, the same record a watcher keeps
}

// The api vtable, with the kernel around it. A plugin holds `&a.api.api`, and that pointer is
// a known offset into the App, so the kernel behind a call is arithmetic rather than a stored
// back-pointer with a second copy of the answer in it.
//
// The App must sit where it will stay before plug_init: a plugin holds a pointer INTO it, and
// no arrangement here survives the App being copied afterwards.
Api_Box :: struct {
    api: plug.Api,
    ctx: runtime.Context, // the kernel's own, so a plugin's allocation frees where it came from
}

// --- loading ---

plug_init :: proc(a: ^App) {
    a.api = {
        api = {
            version = plug.API,
            register_kind = api_register_kind,
            register_command = api_register_command,
            request_bind = api_request_bind,
            register_token = api_register_token,
            register_watch = api_register_watch,
            register_view = api_register_view,
            request_config = api_request_config,
            submit = api_submit,
            reveal = api_reveal,
            cursors = api_cursors,
            snapshot = api_snapshot,
            release = api_release,
            world = api_world,
            world_release = api_world_release,
            message = api_message,
            io_spawn = api_io_spawn,
            io_write = api_io_write,
            io_watch = api_io_watch,
            io_close = api_io_close,
        },
        ctx = context,
    }
}

plug_destroy :: proc(a: ^App) {
    #reverse for _, i in a.plugs {
        plug_unload(a, i)
    }
    for p in a.plugs {
        delete(p.name)
        delete(p.path)
        delete(p.ledger)
        delete(p.seen)
    }
    delete(a.plugs)
    for k in a.kinds {
        delete(k.name)
    }
    delete(a.kinds)
    for c in a.cmds {
        delete(c.name)
        delete(c.doc)
    }
    delete(a.cmds)
    delete(a.insts)
}

plug_find :: proc(a: ^App, name: string) -> int {
    for p, i in a.plugs {
        if p.live && p.name == name {
            return i
        }
    }
    return -1
}

// A plugin registers itself by RUNNING: no manifest, no `.dynsym` audit, no ELF reader. If the
// entry point refuses, the ledger reverts whatever it managed to register first, so a half-way
// load leaves nothing behind.
plug_load :: proc(a: ^App, path: string) -> bool {
    name := strings.trim_suffix(filepath.base(path), ".so")
    if plug_find(a, name) >= 0 {
        message_set(a, fmt.tprintf(":plug: %s is already loaded", name))
        return false
    }
    lib, loaded := dynlib.load_library(path)
    if !loaded {
        message_set(a, fmt.tprintf(":plug: %s: %s", path, dynlib.last_error()))
        return false
    }
    sym, found := dynlib.symbol_address(lib, plug.ENTRY)
    if !found {
        dynlib.unload_library(lib)
        message_set(a, fmt.tprintf(":plug: %s exports no %s", name, plug.ENTRY))
        return false
    }

    quarantine_clear(a, name) // an explicit load is the author saying it is fixed (§13)
    i := plug_slot(a, name, path)
    p := &a.plugs[i]
    p.lib = lib
    p.base = fault_object_base(sym) // where it landed, so §10 can name a pc as its own
    p.gen += 1
    p.live = true
    p.faulted = false

    r, ok := plug_dispatch(a, i, {what = .Entry, entry = (plug.Entry_Fn)(sym)})
    if !ok {
        return false // it died in its entry point; the net unloaded it and said so
    }
    if r.code != 0 {
        plug_unload(a, i)
        message_set(a, fmt.tprintf(":plug: %s refused to load (%d)", name, r.code))
        return false
    }
    // A kind or a command may be named by a row, so both files are read again now that the
    // names resolve. One path in, and a requested row is indistinguishable from a typed one.
    config_sync(a)
    binds_sync(a)
    views_dirty(a)
    return true
}

// Documents first, then the ledger backwards, then the library. A plugin's `close` runs while
// its code is still mapped, which is the only ordering that lets it free what it allocated.
plug_unload :: proc(a: ^App, i: int) -> bool {
    if i < 0 || i >= len(a.plugs) || !a.plugs[i].live {
        return false
    }
    // Collected first: doc_close deletes from `insts`, and walking a map while it is being
    // written is a different bug every time.
    mine := make([dynamic]store.Id, 0, len(a.insts), context.temp_allocator)
    for id, inst in a.insts {
        if inst.owner == i {
            append(&mine, id)
        }
    }
    for id in mine {
        doc_close(a, id) // calls close through plug_inst_close
    }
    io_forget(a, i) // its children die with it, rather than reading into nobody (§9)
    // Its colours go with it, and nobody else's move: a bucket is per publisher, so this is a
    // clear and not a merge (§8). A reload interns the same name again and republishes into it.
    if who, published := producer_find(a, a.plugs[i].name); published {
        store.store_spans_forget(&a.docs, who)
    }
    p := &a.plugs[i]
    #reverse for r in p.ledger {
        switch r.what {
        case .Kind:
            k := &a.kinds[r.idx]
            delete(k.name)
            k^ = {name = "", owner = -1}
        case .Command:
            c := &a.cmds[r.idx]
            delete(c.name)
            delete(c.doc)
            c^ = {name = "", doc = "", owner = -1}
        case .Bind:
            // The row stays in the user's file; only the asking dies (Bind_Request.dead).
            if r.idx < len(a.reqs) {
                a.reqs[r.idx].dead = true
            }
        case .Watch:
            p.watch = nil
            clear(&p.seen)
        case .View:
            p.viewer = nil
        case .Config:
            // The row stays in the user's file; only the asking dies, the same way a bind's
            // request does.
            if r.idx < len(a.creqs) {
                a.creqs[r.idx].dead = true
            }
        }
    }
    clear(&p.ledger)
    // A faulted plugin keeps its mapping: dlclose runs the library's destructors, and that is
    // more of the code that just died. Address space is the cheaper half of that trade (§10).
    if !p.faulted {
        dynlib.unload_library(p.lib)
    }
    p.lib = {}
    p.live = false
    // A shadowing row must fall through to the kernel's, not resolve to the dead slot: the
    // re-read drops every row whose name no longer answers, and the row underneath takes over
    // (CURSORS.md §8). The row stays in the user's file, the way Bind_Request.dead keeps it.
    binds_sync(a)
    views_dirty(a) // a `view =` line naming it resolves to nothing now
    return true
}

// A plugin that died in its own code (§10). Unloaded like any other, except that its `close`
// does not run and its library stays mapped, and NAMED: the bar is where a user finds out that
// what they were using is gone.
plug_faulted :: proc(a: ^App, i: int, why: string) {
    if i < 0 || i >= len(a.plugs) || !a.plugs[i].live {
        return // a nested dispatch may blame the same plugin twice
    }
    a.plugs[i].faulted = true
    name := a.plugs[i].name // owned by the slot, which unloading keeps
    plug_unload(a, i)
    message_set(a, fmt.tprintf(":plug: %s %s, and is unloaded", name, why))
}

// Every `.so` under `<data>/plugins`, at startup, in name order (§14). It leans on the net
// above — a plugin that dies on load must not make oket unstartable — and `--no-plugins` is
// the door for the case the net cannot hold.
plug_autoload :: proc(a: ^App) {
    dir, _ := filepath.join({a.home.data, PLUGIN_DIR}, context.temp_allocator)
    f, err := os.open(dir)
    if err != nil {
        return
    }
    defer os.close(f)
    it := os.read_directory_iterator_create(f)
    defer os.read_directory_iterator_destroy(&it)
    found := make([dynamic]string, context.temp_allocator)
    for info in os.read_directory_iterator(&it) {
        if info.type != .Directory && strings.has_suffix(info.name, ".so") {
            append(&found, strings.clone(info.fullpath, context.temp_allocator))
        }
    }
    // Sorted, so which kind registers first is a property of the names and not of the
    // directory's order.
    slice.sort(found[:])
    held := make([dynamic]string, context.temp_allocator)
    for path in found {
        // A plugin an earlier start died IN is not loaded into this one (§13). The check is
        // here rather than in plug_load, because plug_load is also how the quarantine is
        // lifted: `:plug load <name>` is the author saying they fixed it.
        name := strings.trim_suffix(filepath.base(path), ".so")
        if quarantined(a, name) {
            append(&held, name)
            continue
        }
        plug_load(a, path)
    }
    if len(held) > 0 {
        message_set(a, fmt.tprintf(":plug: %s took a start down and %s not loaded (:plug load)",
                                   strings.join(held[:], ", ", context.temp_allocator),
                                   len(held) == 1 ? "is" : "are"))
    }
}

// The loop `:pluginify` exists for. Unload then load, so the ledger reverts before the new
// library's registrations go on and the two loads never share a slot id.
plug_reload :: proc(a: ^App, name: string) -> bool {
    i := plug_find(a, name)
    if i < 0 {
        message_set(a, fmt.tprintf(":plug: %s is not loaded", name))
        return false
    }
    path := strings.clone(a.plugs[i].path, context.temp_allocator)
    plug_unload(a, i)
    return plug_load(a, path)
}

plug_path :: proc(a: ^App, name: string) -> string {
    file := fmt.tprintf("%s.so", name)
    path, _ := filepath.join({a.home.data, PLUGIN_DIR, file}, context.temp_allocator)
    return path
}

// --- the documents a plugin opens ---

// The kernel makes the document and the descriptor's baseline; the plugin fills both in with a
// submit. So a plugin's document is a document before its code has run, which is what keeps a
// plugin that refuses to open from leaving a slot half made.
plug_open :: proc(a: ^App, kind: input.Kind, args := "") -> (store.Id, bool) {
    k, ok := plug_kind(a, kind)
    if !ok || k.vt.open == nil {
        return {}, false
    }
    id := store.store_open(&a.docs)
    gen, _ := store.store_gen(&a.docs, id)
    d := desc.new_from({ctx = k.ctx, kind = kind, selection = .Line})
    store.store_submit(&a.docs, id, gen, nil, d)
    desc.release(d)
    store.store_drain(&a.docs)

    r, ran := plug_dispatch(a, k.owner, {what = .Open, vt = k.vt, doc = plug_doc(id),
                                         data = transmute([]u8)args})
    if !ran {
        // The document is the kernel's and was never handed to anyone, so the unload that just
        // ran could not have closed it: `insts` does not know about it yet.
        doc_close(a, id)
        return {}, false
    }
    docs_settle(a) // whatever `open` submitted, before anyone reads it
    // `open` FILLS a document; it does not EDIT one. The transaction that filled it went
    // through the funnel a keystroke uses, so without this the caret sits at the end of what
    // was loaded and the first undo takes the buffer back to empty.
    if doc := store.store_doc(&a.docs, id); doc != nil {
        txt.doc_forget_undo(doc)
        txt.doc_reset_cursor(doc, {})
    }
    gen, _ = store.store_gen(&a.docs, id) // where `open` left it, so nothing is reported back
    a.insts[id] = {k.owner, kind, r.inst, {gen = gen}}
    return id, true
}

// Called by doc_close for every document, so a plugin's instance ends wherever the document
// does — `:close`, `alt+q`, or the plugin unloading under it.
plug_inst_close :: proc(a: ^App, id: store.Id) {
    inst, held := a.insts[id]
    if !held {
        return
    }
    delete_key(&a.insts, id)
    p := &a.plugs[inst.owner]
    k, ok := plug_kind(a, inst.kind)
    // Not for a plugin that faulted: its code is what died, and calling more of it to tidy up
    // is how one fault becomes two (§10).
    if p.live && !p.faulted && ok && k.vt.close != nil {
        _, _ = plug_dispatch(a, inst.owner, {what = .Close, vt = k.vt, doc = plug_doc(id),
                                             inst = inst.inst})
    }
}

// --- the two kernel -> plugin messages that are not open and close ---

// A chord the bind table routed to this document because its descriptor says `input: raw`
// (§5, §8). False means nothing took it, and the caller decides whether that reports.
plug_send :: proc(a: ^App, id: store.Id, chord: input.Chord) -> bool {
    return plug_event(a, id, .Chord, input.chord_physical(chord, context.temp_allocator))
}

// A rune typed into a document whose descriptor says `input: raw`. Not a chord: binds see
// chords and never see an `a` on its way into a document (§8).
plug_type :: proc(a: ^App, id: store.Id, r: rune) -> bool {
    return plug_event(a, id, .Text, utf8.runes_to_string({r}, context.temp_allocator))
}

@(private = "file")
plug_event :: proc(a: ^App, id: store.Id, ev: plug.Event, text: string) -> bool {
    inst, held := a.insts[id]
    if !held {
        return false
    }
    k, ok := plug_kind(a, inst.kind)
    if !ok || k.vt.event == nil {
        return false
    }
    at, free_view := plug_at(a, inst.owner, id)
    defer view_free(free_view)
    r, ran := plug_dispatch(a, inst.owner, {what = .Event, vt = k.vt, at = &at, ev = ev,
                                            data = transmute([]u8)text})
    if !ran {
        return false
    }
    // A plugin's transaction lands when its call RETURNS, the same way `open`'s does. Holding
    // it to the end of the frame would drop the second of two keystrokes in one: both would be
    // written against the generation the first has not moved yet, and the drain refuses a
    // stale one whole (§6). Typing is two events, not one.
    docs_settle(a)
    return r.code != 0
}

// A generation that moved (§5). The owner is told, so a REPL whose transcript a formatter
// rewrote can re-read and repair its own editable span. Nothing ELSE needs telling: a read is a
// snapshot and a write against a stale one is refused at the drain, which is what makes "anyone
// may write anyone's buffer" safe without a gate (§7).
// The return is whether anybody asked to be called again (§9). A latched plugin is the one
// case the frame loop must not idle in: nothing external is coming to wake it, and the work is
// half done.
plug_pump :: proc(a: ^App) -> (latched: bool) {
    return plug_pump_insts(a) | plug_pump_watch(a)
}

// A document a plugin OPENED, whose generation moved. It hears through its kind's `event`.
@(private = "file")
plug_pump_insts :: proc(a: ^App) -> (latched: bool) {
    // Who to tell is decided first: a `moved` handler that faults unloads its plugin, and that
    // DELETES from `insts` — walking a map while it is being written is a different bug every
    // time. Same rule as plug_unload's.
    moved := make([dynamic]store.Id, 0, len(a.insts), context.temp_allocator)
    landed := store.store_landed(&a.docs)
    for id, &inst in a.insts {
        gen, live := store.store_gen(&a.docs, id)
        if !live {
            continue
        }
        if watch_due(inst.told, gen, landed) {
            append(&moved, id)
        }
        inst.told = {gen = gen}
    }
    for id in moved {
        inst, held := a.insts[id]
        if !held {
            continue // its plugin died earlier in this same loop
        }
        k, ok := plug_kind(a, inst.kind)
        if !ok || k.vt.event == nil {
            continue
        }
        at, free_view := plug_at(a, inst.owner, id)
        defer view_free(free_view)
        r, live := plug_dispatch(a, inst.owner, {what = .Event, vt = k.vt, at = &at, ev = .Moved})
        if live {
            if held := &a.insts[id]; held != nil {
                held.latch = r.code != 0
                latched |= held.latch
            }
        }
    }
    return
}

// A document a WATCHER did not open. It is told about every one it has not seen at the
// generation the document is at now, which is the open notice and the moved notice in one rule
// (§9). A non-zero return is the latch, same as above.
@(private = "file")
plug_pump_watch :: proc(a: ^App) -> (latched: bool) {
    ids := store.store_ids(&a.docs)
    landed := store.store_landed(&a.docs)
    for i in 0 ..< len(a.plugs) {
        if !a.plugs[i].live || a.plugs[i].watch == nil {
            continue
        }
        // Decided before any of them is dispatched, for plug_pump_insts' reason: a fault in
        // here clears `seen` out from under the walk.
        tell := make([dynamic]store.Id, 0, len(ids), context.temp_allocator)
        for id in ids {
            gen, _ := store.store_gen(&a.docs, id)
            w, told := a.plugs[i].seen[id]
            if !told || watch_due(w, gen, landed) {
                append(&tell, id)
            }
            a.plugs[i].seen[id] = {gen = gen}
        }
        watch_prune(a, i, ids)
        for id in tell {
            if !a.plugs[i].live {
                break // it faulted on an earlier document in this same loop
            }
            fn := a.plugs[i].watch
            at, free_view := plug_at(a, i, id)
            defer view_free(free_view)
            r, live := plug_dispatch(a, i, {what = .Watch, fn_ev = fn, at = &at, ev = .Moved})
            if live {
                if w, held := &a.plugs[i].seen[id]; held {
                    w.latch = r.code != 0
                    latched |= w.latch
                }
            }
        }
    }
    return
}

// Whether the record's holder must hear `.Moved`: it latched, or the generation moved under it
// and not by its own landed write.
@(private = "file")
watch_due :: proc(w: Watch, gen: u64, landed: []u64) -> bool {
    mine := w.tag != 0 && slice.contains(landed, w.tag)
    return w.latch || (gen != w.gen && !mine)
}

// A document that closed leaves a dead key behind, and an Id is a slot plus a seq, so the slot
// coming back as somebody else's document reads as unseen — which is what it is.
@(private = "file")
watch_prune :: proc(a: ^App, i: int, ids: []store.Id) {
    dead := make([dynamic]store.Id, 0, len(a.plugs[i].seen), context.temp_allocator)
    for id in a.plugs[i].seen {
        if !slice.contains(ids, id) {
            append(&dead, id)
        }
    }
    for id in dead {
        delete_key(&a.plugs[i].seen, id)
    }
}

// A registered command, run from the command line or from a bind row (§12).
plug_command :: proc(a: ^App, slot: input.Slot, args: string) -> bool {
    i := int(slot)
    if i < 0 || i >= len(a.cmds) || a.cmds[i].owner < 0 {
        message_set(a, "that command's plugin is not loaded")
        return false
    }
    c := a.cmds[i]
    at: plug.At
    view: ^Plug_View
    if s := ring_focused(a); s != nil {
        at, view = plug_at(a, c.owner, s.doc)
    }
    defer view_free(view)
    r, ok := plug_dispatch(a, c.owner, {what = .Command, fn = c.fn, at = &at,
                                        data = transmute([]u8)arg_whole(args)})
    if !ok {
        return false
    }
    docs_settle(a) // what it wrote is landed before the next step of a chain reads it
    return r.code == 0
}

plug_cmd_named :: proc(a: ^App, name: string) -> (input.Slot, bool) {
    for c, i in a.cmds {
        if c.owner >= 0 && c.name == name {
            return input.Slot(i), true
        }
    }
    return 0, false
}

// --- the one door into plugin code (§10) ---

// What a call answers. `open` returns an instance and everything else an exit code, so one
// shape covers the five and no caller reads a field that call could not have filled.
Plug_Ret :: struct {
    inst: rawptr,
    code: i32,
}

// A call, as data. It is a struct rather than five wrappers because the sigsetjmp below has to
// sit in the frame that MAKES the call: the handler's siglongjmp lands there, and a frame that
// has already returned is not one to jump into.
Plug_Call :: struct {
    what:    enum {
        Entry,
        Open,
        Close,
        Event,
        Watch,
        Command,
        View,
    },
    entry:   plug.Entry_Fn,
    vt:      plug.Kind_Vt,
    fn:      plug.Command_Fn,
    fn_ev:   plug.Event_Fn, // a watcher's, which belongs to no kind
    fn_view: plug.View_Fn, // a view stage's, which belongs to no kind either
    doc:     plug.Doc,
    at:      ^plug.At,
    inst:    rawptr,
    ev:      plug.Event,
    data:    []u8,
    out:     ^plug.View_Out,
}

// EVERY call into a plugin goes through here, and nothing else calls one. A fault or a hang in
// there comes back as `ok = false` with the plugin unloaded and named, and the kernel carries
// on; a fault anywhere else is the kernel's own and dies honestly (fault.odin).
plug_dispatch :: proc(a: ^App, i: int, c: Plug_Call) -> (r: Plug_Ret, ok: bool) {
    // A PLUGIN THAT RAN IS A PLUGIN WHOSE VIEW MAY HAVE CHANGED (VIEWS.md §5). A fold toggled by
    // a command moves no generation and no caret, and there is nothing in a stage's own state
    // the kernel can watch — so running its code is the signal, and it needs no seventh message.
    // The view call itself is excluded, or every settle would invalidate the chain it just built.
    if c.what != .View {
        views_dirty(a)
    }
    // Nothing dispatches from inside a dispatch today. If that ever changes, the outer net
    // still catches the fault; it just blames the outer plugin.
    if !fault_ready() || fault_armed() {
        r = plug_run(a, i, c)
        return r, plug_intact(a, i)
    }
    if sigsetjmp(fault_env(), 1) != 0 {
        fault_reap() // reads the guard, never this frame: those registers made no promises
        return {}, false
    }
    fault_arm(a, i, a.plugs[i].base, a.plugs[i].name)
    r = plug_run(a, i, c)
    fault_disarm()
    return r, plug_intact(a, i)
}

// The invariant checks (§10), at the one place that knows who was just driving. A plugin that
// returns cleanly having smashed a document is caught here rather than four frames later inside
// kernel code, and it costs three O(1) reads per open document.
@(private = "file")
plug_intact :: proc(a: ^App, i: int) -> bool {
    if store.store_check(&a.docs) {
        return true
    }
    plug_faulted(a, i, "left a document corrupt")
    return false
}

@(private = "file")
plug_run :: proc(a: ^App, i: int, c: Plug_Call) -> (r: Plug_Ret) {
    api, self := &a.api.api, plug_self(a, i)
    switch c.what {
    case .Entry:
        r.code = c.entry(api, self)
    case .Open:
        r.inst = c.vt.open(api, self, c.doc, raw_data(c.data), len(c.data))
    case .Close:
        c.vt.close(api, self, c.doc, c.inst)
    case .Event:
        r.code = c.vt.event(api, self, c.at, c.ev, raw_data(c.data), len(c.data))
    case .Watch:
        r.code = c.fn_ev(api, self, c.at, c.ev, raw_data(c.data), len(c.data))
    case .Command:
        r.code = c.fn(api, self, c.at, raw_data(c.data), len(c.data))
    case .View:
        r.code = c.fn_view(api, self, c.at, c.out)
    }
    return
}

// --- the api, as a plugin sees it ---

@(private = "file")
api_register_kind :: proc "c" (api: ^plug.Api, self: plug.Self,
                               spec: ^plug.Kind_Spec) -> input.Kind {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok || spec == nil {
        return 0
    }
    context = a.api.ctx
    name := string(spec.name[:spec.name_len])
    if name == "" {
        return 0
    }
    if _, taken := kind_named(a, name); taken {
        message_set(a, fmt.tprintf("%s: a kind called %s is already registered",
                                   a.plugs[i].name, name))
        return 0
    }
    ctx_name := spec.ctx_len > 0 ? string(spec.ctx[:spec.ctx_len]) : "surface"
    ctx, known := input.ctx_named(ctx_name)
    if !known || ctx == .Global {
        message_set(a, fmt.tprintf("%s: %s is not a bind context", a.plugs[i].name, ctx_name))
        return 0
    }
    append(&a.kinds, Plug_Kind{strings.clone(name), ctx, i, spec.vt})
    append(&a.plugs[i].ledger, Record{.Kind, len(a.kinds) - 1})
    return input.Kind(len(KINDS) + len(a.kinds))
}

@(private = "file")
api_register_command :: proc "c" (api: ^plug.Api, self: plug.Self, name: [^]u8,
                                  name_len: uint, doc: [^]u8, doc_len: uint,
                                  fn: plug.Command_Fn) {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok || fn == nil {
        return
    }
    context = a.api.ctx
    n := string(name[:name_len])
    if n == "" || strings.contains(n, " ") {
        return // a name with a space in it could never be typed back
    }
    if _, taken := plug_cmd_named(a, n); taken {
        message_set(a, fmt.tprintf("%s: :%s is already registered", a.plugs[i].name, n))
        return
    }
    append(&a.cmds, Plug_Cmd{strings.clone(n), strings.clone(string(doc[:doc_len])), i, fn})
    append(&a.plugs[i].ledger, Record{.Command, len(a.cmds) - 1})
}

@(private = "file")
api_request_bind :: proc "c" (api: ^plug.Api, self: plug.Self, ctx: [^]u8, ctx_len: uint,
                              chord: [^]u8, chord_len: uint, line: [^]u8, line_len: uint) {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = a.api.ctx
    binds_request(a, a.plugs[i].name, string(ctx[:ctx_len]), string(chord[:chord_len]),
                  string(line[:line_len]))
    append(&a.plugs[i].ledger, Record{.Bind, len(a.reqs) - 1})
}

@(private = "file")
api_register_token :: proc "c" (api: ^plug.Api, self: plug.Self, name: [^]u8,
                                name_len: uint) -> plug.Token {
    a, _, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return plug.Token(plug.Style.Fg)
    }
    context = a.api.ctx
    return token_intern(a, string(name[:name_len]))
}

@(private = "file")
api_register_view :: proc "c" (api: ^plug.Api, self: plug.Self, fn: plug.View_Fn) {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok || fn == nil {
        return
    }
    context = a.api.ctx
    p := &a.plugs[i]
    if p.viewer == nil { // registering twice replaces, and leaves one ledger record
        append(&p.ledger, Record{.View, 0})
    }
    p.viewer = fn
    views_dirty(a) // a name in a `view =` line resolves to something it did not a moment ago
}

@(private = "file")
api_request_config :: proc "c" (api: ^plug.Api, self: plug.Self, section: [^]u8,
                                section_len: uint, key: [^]u8, key_len: uint,
                                value: [^]u8, value_len: uint) {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = a.api.ctx
    if config_request(a, a.plugs[i].name, string(section[:section_len]), string(key[:key_len]),
                      string(value[:value_len])) {
        append(&a.plugs[i].ledger, Record{.Config, len(a.creqs) - 1})
    }
}

@(private = "file")
api_register_watch :: proc "c" (api: ^plug.Api, self: plug.Self, fn: plug.Event_Fn) {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok || fn == nil {
        return
    }
    context = a.api.ctx
    p := &a.plugs[i]
    if p.watch == nil { // registering twice replaces, and leaves one ledger record
        append(&p.ledger, Record{.Watch, 0})
    }
    p.watch = fn
    clear(&p.seen)
}

@(private = "file")
api_submit :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc, gen: u64,
                        edits: [^]plug.Edit, nedits: uint, d: ^plug.Descriptor,
                        spans: ^plug.Span_Pub, flags: u32) {
    a, i, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = a.api.ctx
    id := store_id(doc)
    own := make([]txt.Edit, nedits, context.temp_allocator)
    for e, n in edits[:nedits] {
        own[n] = {int(e.lo), int(e.hi), string(e.text[:e.text_len]), 0, e.id}
    }
    nd := d != nil ? plug_desc_take(a, id, d) : nil
    defer desc.release(nd)
    tag := store.store_submit(&a.docs, id, gen, own, nd, plug_spans_take(a, i, spans),
                              .Regen in transmute(plug.Submit_Flags)flags)
    if inst, held := &a.insts[id]; held && inst.owner == i {
        inst.tag = tag
    }
    if w, held := &a.plugs[i].seen[id]; held {
        w.tag = tag
    }
}

// A publish, with its tokens RESOLVED against the palette on the way in (tokens.odin). The
// seam speaks tokens and the store speaks colours, the same split plug_desc_take makes for a
// descriptor: a plugin that named a colour would break every theme, and the renderer that
// looked one up per cell would do it per frame instead of per publish.
//
// WHO published is the caller, not a field it filled in, so a plugin cannot replace another's
// runs however it is compiled. One token per run, and `set` says which channel it paints: a
// colour that is not claimed as a foreground or a background is not drawn at all.
@(private = "file")
plug_spans_take :: proc(a: ^App, plugin: int, pub: ^plug.Span_Pub) -> Maybe(store.Spans) {
    if pub == nil {
        return nil
    }
    list := make([]store.Span, pub.nspans, context.temp_allocator)
    for sp, n in pub.spans[:pub.nspans] {
        color := token_color(a, sp.tok)
        set := sp.set & desc.Chans{.Fg, .Bg, .Attrs} // untrusted byte: stray bits are not channels
        list[n] = {
            lo    = int(min(sp.lo, uint(max(int)))),
            hi    = int(min(sp.hi, uint(max(int)))),
            fg    = .Fg in set ? color : {},
            bg    = .Bg in set ? color : {},
            attrs = sp.attrs,
            set   = set,
        }
    }
    return store.Spans{
        who  = producer_intern(a, a.plugs[plugin].name),
        lo   = int(min(pub.lo, uint(max(int)))),
        hi   = int(min(pub.hi, uint(max(int)))),
        list = list,
    }
}

@(private = "file")
api_world :: proc "c" (api: ^plug.Api, self: plug.Self) -> ^plug.World {
    a, _, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return nil
    }
    context = a.api.ctx
    return &world_make(a).world
}

@(private = "file")
api_world_release :: proc "c" (api: ^plug.Api, self: plug.Self, w: ^plug.World) {
    a, _, ok := api_app(api, self)
    defer api_done()
    if !ok || w == nil {
        return
    }
    context = a.api.ctx
    world_free((^Plug_World)(w)) // `world` is the first field, so the cast is the identity
}

@(private = "file")
api_reveal :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc,
                        lo: uint, hi: uint, at: plug.Reveal) {
    a, _, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = a.api.ctx
    reveal_span(a, store_id(doc), int(lo), int(hi), at)
}

// Queued on the slot rather than written now: the submit it belongs to has not landed yet, and
// the drain rebuilds the cursors after every splice it applies (store_cursors).
@(private = "file")
api_cursors :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc,
                         curs: [^]plug.Cursor, n: uint, primary: uint) {
    a, _, ok := api_app(api, self)
    defer api_done()
    if !ok || curs == nil || n == 0 {
        return
    }
    context = a.api.ctx
    set := transmute([]txt.Cursor)curs[:n]
    store.store_cursors(&a.docs, store_id(doc), set, int(min(primary, n - 1)))
}

@(private = "file")
api_snapshot :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc) -> ^plug.Snapshot {
    a, _, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return nil
    }
    context = a.api.ctx
    v := view_hold(a, store_id(doc))
    return v != nil ? &v.snap : nil
}

@(private = "file")
api_release :: proc "c" (api: ^plug.Api, self: plug.Self, snap: ^plug.Snapshot) {
    a, _, ok := api_app(api, self)
    defer api_done()
    if !ok || snap == nil {
        return
    }
    context = a.api.ctx
    view_free((^Plug_View)(snap))
}

@(private = "file")
api_message :: proc "c" (api: ^plug.Api, self: plug.Self, text: [^]u8, text_len: uint) {
    a, _, ok := api_app(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = a.api.ctx
    message_set(a, string(text[:text_len]))
}

// The kernel behind the pointer, and the plugin the handle names. A Self from an earlier load
// carries the wrong generation and is refused here, which is the whole reason it is packed.
// Package-wide rather than file-private because io.odin's arms are api arms like these two.
@(private)
api_app :: proc "c" (api: ^plug.Api, self: plug.Self) -> (a: ^App, i: int, ok: bool) {
    if api == nil {
        return nil, 0, false
    }
    a = (^App)(uintptr(api) - offset_of(App, api))
    i = int(u64(self) & 0xffff_ffff)
    gen := u32(u64(self) >> 32)
    if i < 0 || i >= len(a.plugs) || !a.plugs[i].live || a.plugs[i].gen != gen {
        return nil, 0, false
    }
    // §10's second guard opens here: from now until api_done the kernel is writing its own
    // structures on this plugin's behalf, and a fault in that window is not one to unwind.
    fault_busy(true)
    return a, i, true
}

@(private)
api_done :: proc "c" () {
    fault_busy(false)
}

// --- handles ---

plug_self :: proc(a: ^App, i: int) -> plug.Self {
    return plug.Self(u64(u32(i)) | u64(a.plugs[i].gen) << 32)
}

plug_doc :: proc(id: store.Id) -> plug.Doc {
    return plug.Doc(u64(id.slot) | u64(id.seq) << 32)
}

store_id :: proc(doc: plug.Doc) -> store.Id {
    return {u32(u64(doc) & 0xffff_ffff), u32(u64(doc) >> 32)}
}

// --- internals ---

// A slot per NAME, reused across loads so a reload does not grow the table forever. The
// generation is what makes an old Self refuse; the index alone would not.
@(private = "file")
plug_slot :: proc(a: ^App, name, path: string) -> int {
    for &p, i in a.plugs {
        if !p.live && p.name == name {
            delete(p.path)
            p.path = strings.clone(path)
            return i
        }
    }
    append(&a.plugs, Plugin{name = strings.clone(name), path = strings.clone(path)})
    return len(a.plugs) - 1
}

plug_kind :: proc(a: ^App, kind: input.Kind) -> (Plug_Kind, bool) {
    i := int(kind) - len(KINDS) - 1
    if i < 0 || i >= len(a.kinds) || a.kinds[i].owner < 0 {
        return {}, false
    }
    return a.kinds[i], true
}

// Where a call is happening: the focused document, its text, and the instance pointer only
// when that document is the CALLER's own — another plugin's inst would be a deref through a
// struct of another shape (§5). The view is the caller's to free.
@(private = "file")
plug_at :: proc(a: ^App, i: int, id: store.Id) -> (plug.At, ^Plug_View) {
    v := view_make(a, id)
    if v == nil {
        return {}, nil
    }
    inst := a.insts[id]
    return {doc = plug_doc(id), inst = inst.owner == i ? inst.inst : nil, snap = &v.snap}, v
}

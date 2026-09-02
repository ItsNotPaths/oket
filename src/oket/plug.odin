package main

import "base:runtime"
import "core:dynlib"
import "core:fmt"
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

PLUGIN_DIR :: "plugins" // beside the binary, next to binds.conf

Plugin :: struct {
    name:   string, // owned; the file's stem, and the section header in binds.conf
    path:   string, // owned
    lib:    dynlib.Library,
    gen:    u32, // bumped per load, so a Self from an earlier load is refused
    live:   bool,
    ledger: [dynamic]Record,
}

Record_Kind :: enum u8 {
    Kind,
    Command,
    Bind,
}

Record :: struct {
    what: Record_Kind,
    idx:  int, // into a.kinds, a.cmds or a.reqs
}

// A kind a plugin registered, appended past the kernel's three (kinds.odin). `owner` goes to -1
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
    owner: int,
    kind:  input.Kind,
    inst:  rawptr,
    gen:   u64, // last generation this instance was told about
    // The owner's own transaction, still waiting on the drain. A generation this moved is not
    // reported back, or a plugin that re-reads on `moved` would answer its own write forever.
    // The TAG and not a flag: a submit that loses the race is dropped, and that case is exactly
    // when the owner has to be told.
    tag:   u64,
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
            submit = api_submit,
            reveal = api_reveal,
            snapshot = api_snapshot,
            release = api_release,
            message = api_message,
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

    i := plug_slot(a, name, path)
    p := &a.plugs[i]
    p.lib = lib
    p.gen += 1
    p.live = true

    code := (plug.Entry_Fn)(sym)(&a.api.api, plug_self(a, i))
    if code != 0 {
        plug_unload(a, i)
        message_set(a, fmt.tprintf(":plug: %s refused to load (%d)", name, code))
        return false
    }
    // A kind or a command may be named by a row, so the file is read again now that the names
    // resolve. One path in, and a requested row is indistinguishable from a typed one (§8).
    binds_sync(a)
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
        }
    }
    clear(&p.ledger)
    dynlib.unload_library(p.lib)
    p.lib = {}
    p.live = false
    return true
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
    path, _ := filepath.join({a.home, PLUGIN_DIR, file}, context.temp_allocator)
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

    arg := transmute([]u8)args
    inst := k.vt.open(&a.api.api, plug_self(a, k.owner), plug_doc(id), raw_data(arg), len(arg))
    store.store_drain(&a.docs) // whatever `open` submitted, before anyone reads it
    gen, _ = store.store_gen(&a.docs, id) // where `open` left it, so nothing is reported back
    a.insts[id] = {k.owner, kind, inst, gen, 0}
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
    if p.live && ok && k.vt.close != nil {
        k.vt.close(&a.api.api, plug_self(a, inst.owner), plug_doc(id), inst.inst)
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
    bytes := transmute([]u8)text
    at, free_view := plug_at(a, inst.owner, id)
    defer view_free(free_view)
    return k.vt.event(&a.api.api, plug_self(a, inst.owner), &at, ev,
                      raw_data(bytes), len(bytes)) != 0
}

// A generation that moved (§5). The owner is told, so a REPL whose transcript a formatter
// rewrote can re-read and repair its own editable span. Nothing ELSE needs telling: a read is a
// snapshot and a write against a stale one is refused at the drain, which is what makes "anyone
// may write anyone's buffer" safe without a gate (§7).
plug_pump :: proc(a: ^App) {
    for id, &inst in a.insts {
        gen, live := store.store_gen(&a.docs, id)
        if !live || gen == inst.gen {
            continue
        }
        mine := inst.tag != 0 && slice.contains(store.store_landed(&a.docs), inst.tag)
        inst.gen = gen
        inst.tag = 0
        if mine {
            continue
        }
        k, ok := plug_kind(a, inst.kind)
        if !ok || k.vt.event == nil {
            continue
        }
        at, free_view := plug_at(a, inst.owner, id)
        defer view_free(free_view)
        k.vt.event(&a.api.api, plug_self(a, inst.owner), &at, .Moved, nil, 0)
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
    if s := ring_focused(&a.ring); s != nil {
        at, view = plug_at(a, c.owner, s.doc)
    }
    defer view_free(view)
    bytes := transmute([]u8)args
    return c.fn(&a.api.api, plug_self(a, c.owner), &at, raw_data(bytes), len(bytes)) == 0
}

plug_cmd_named :: proc(a: ^App, name: string) -> (input.Slot, bool) {
    for c, i in a.cmds {
        if c.owner >= 0 && c.name == name {
            return input.Slot(i), true
        }
    }
    return 0, false
}

// --- the api, as a plugin sees it ---

@(private = "file")
api_register_kind :: proc "c" (api: ^plug.Api, self: plug.Self,
                               spec: ^plug.Kind_Spec) -> input.Kind {
    a, i, ok := api_app(api, self)
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
    if !ok {
        return
    }
    context = a.api.ctx
    binds_request(a, a.plugs[i].name, string(ctx[:ctx_len]), string(chord[:chord_len]),
                  string(line[:line_len]))
    append(&a.plugs[i].ledger, Record{.Bind, len(a.reqs) - 1})
}

@(private = "file")
api_submit :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc, gen: u64,
                        edits: [^]plug.Edit, nedits: uint, d: ^plug.Descriptor) {
    a, i, ok := api_app(api, self)
    if !ok {
        return
    }
    context = a.api.ctx
    id := store_id(doc)
    own := make([]txt.Edit, nedits, context.temp_allocator)
    for e, n in edits[:nedits] {
        own[n] = {int(e.lo), int(e.hi), string(e.text[:e.text_len]), 0}
    }
    nd := d != nil ? plug_desc_take(a, id, d) : nil
    defer desc.release(nd)
    tag := store.store_submit(&a.docs, id, gen, own, nd)
    if inst, held := &a.insts[id]; held && inst.owner == i {
        inst.tag = tag
    }
}

@(private = "file")
api_reveal :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc,
                        lo: uint, hi: uint, at: plug.Reveal) {
    a, _, ok := api_app(api, self)
    if !ok {
        return
    }
    context = a.api.ctx
    reveal_span(a, store_id(doc), int(lo), int(hi), at)
}

@(private = "file")
api_snapshot :: proc "c" (api: ^plug.Api, self: plug.Self, doc: plug.Doc) -> ^plug.Snapshot {
    a, _, ok := api_app(api, self)
    if !ok {
        return nil
    }
    context = a.api.ctx
    v := view_make(a, store_id(doc))
    return v != nil ? &v.snap : nil
}

@(private = "file")
api_release :: proc "c" (api: ^plug.Api, self: plug.Self, snap: ^plug.Snapshot) {
    a, _, ok := api_app(api, self)
    if !ok || snap == nil {
        return
    }
    context = a.api.ctx
    view_free((^Plug_View)(snap))
}

@(private = "file")
api_message :: proc "c" (api: ^plug.Api, self: plug.Self, text: [^]u8, text_len: uint) {
    a, _, ok := api_app(api, self)
    if !ok {
        return
    }
    context = a.api.ctx
    message_set(a, string(text[:text_len]))
}

// The kernel behind the pointer, and the plugin the handle names. A Self from an earlier load
// carries the wrong generation and is refused here, which is the whole reason it is packed.
@(private = "file")
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
    return a, i, true
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
    return {plug_doc(id), inst.owner == i ? inst.inst : nil, &v.snap}, v
}

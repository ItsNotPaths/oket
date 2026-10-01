package main

import "core:unicode/utf8"
import "lues:abi"
import "lues:docs"
import "lues:lues"
import "../desc"
import "../input"
import "../plug"
import "../store"
import "../txt"

// The plugin seam, kernel side (§7). lues is the kernel: the loader and its ledger, dispatch and
// the fault net, io, tokens and requests. This file is oket on top of it: the hooks lues calls
// back into, oket's tail of the api (plug.Api), and the names the rest of oket calls it by.

PLUGIN_DIR :: lues.PLUGIN_DIR

// lues's kernel and the vtable plugins hold. On the heap: neither may move once started, and an
// App is a handle tests pass by value.
Kernel :: struct {
    using base: lues.Kernel,
    box:        lues.Box(plug.Api),
}

// A ledger record of oket's own (lues.ledger_add), handed back to hooks.unregister.
RECORD_VIEW :: 1

// What a plugin described for its next submit to one doc.
Staged :: struct {
    self: abi.Self,
    doc:  docs.Id,
}

// After the App's state exists; `home` is borrowed from it and kept in step by app_home.
kernel_open :: proc(a: ^App, unguarded := false) -> bool {
    a.kernel = new(Kernel)
    k := a.kernel
    base := make([]string, len(BASE_TOKENS), context.temp_allocator)
    for name, i in BASE_TOKENS {
        base[i] = name
    }
    ok := lues.kernel_init(k, {
        home        = kernel_home(a.home),
        app         = "oket",
        app_version = plug.API,
        kind_base   = len(KINDS),
        base_tokens = base,
        hooks       = HOOKS,
        api         = &k.box.api.lues,
        user        = a.state,
        unguarded   = unguarded,
    })
    k.box.api.describe = api_describe
    k.box.api.reveal = api_reveal
    k.box.api.cursors = api_cursors
    k.box.api.register_view = api_register_view
    k.box.api.world = api_world
    k.box.api.world_release = api_world_release
    a.docs = &k.store
    return ok
}

// Plugins first, while their documents are still there to close, then oket's half of every
// document left, then lues.
kernel_close :: proc(a: ^App) {
    k := a.kernel
    if k == nil {
        return
    }
    #reverse for _, i in k.plugs {
        lues.loader_unload(k, i)
    }
    store.store_destroy(&k.store)
    lues.kernel_destroy(k)
    for _, d in a.staged {
        desc.release(d)
    }
    delete(a.staged)
    delete(a.viewers)
    free(k)
    a.kernel, a.docs = nil, nil
}

kernel_home :: proc(h: Home) -> lues.Home {
    return {config = h.config, data = h.data, state = h.state}
}

// --- the names the rest of oket calls the seam by ---

plug_load :: proc(a: ^App, path: string) -> bool {
    return lues.loader_load(a.kernel, path)
}

plug_unload :: proc(a: ^App, i: int) -> bool {
    return lues.loader_unload(a.kernel, i)
}

plug_reload :: proc(a: ^App, name: string) -> bool {
    return lues.loader_reload(a.kernel, name)
}

plug_find :: proc(a: ^App, name: string) -> int {
    return lues.loader_find(a.kernel, name)
}

plug_path :: proc(a: ^App, name: string) -> string {
    return lues.loader_path(a.kernel, name)
}

plug_autoload :: proc(a: ^App) {
    lues.loader_autoload(a.kernel)
}

// `open` FILLS a document; it does not EDIT one. Its submits went through the funnel a
// keystroke uses, so without this the caret sits at the end of what was loaded and the first
// undo takes the buffer back to empty.
plug_open :: proc(a: ^App, kind: input.Kind, args := "") -> (store.Id, bool) {
    id, ok := lues.inst_open(a.kernel, lues.Kind(kind), args)
    if !ok {
        return {}, false
    }
    docs_settle(a)
    if doc := store.store_doc(a.docs, id); doc != nil {
        txt.doc_forget_undo(doc)
        txt.doc_reset_cursor(doc, {})
    }
    return id, true
}

// After each call below, oket's own settle: lues landed the writes, and this is where the view
// pipeline, the journal and the caret follow catch up.

// A chord the bind table routed here because the descriptor says `input: raw` (§5, §8).
plug_send :: proc(a: ^App, id: store.Id, chord: input.Chord) -> bool {
    defer docs_settle(a)
    return lues.inst_event(a.kernel, id, .Chord, input.chord_physical(chord, context.temp_allocator))
}

// A rune typed into a raw document. Binds never see an `a` on its way in (§8).
plug_type :: proc(a: ^App, id: store.Id, r: rune) -> bool {
    defer docs_settle(a)
    return lues.inst_event(a.kernel, id, .Text, utf8.runes_to_string({r}, context.temp_allocator))
}

// A registered command, from the command line or a bind row (§12), on the focused document.
plug_command :: proc(a: ^App, slot: input.Slot, args: string) -> bool {
    focused: Maybe(store.Id)
    if s := ring_focused(a); s != nil {
        focused = s.doc
    }
    // What it wrote is landed and drawn before the next step of a chain reads it.
    defer docs_settle(a)
    return lues.cmd_run(a.kernel, int(slot), focused, arg_whole(args))
}

plug_cmd_named :: proc(a: ^App, name: string) -> (input.Slot, bool) {
    slot, ok := lues.cmd_named(a.kernel, name)
    return input.Slot(slot), ok
}

plug_kind :: proc(a: ^App, kind: input.Kind) -> (lues.Plug_Kind, bool) {
    return lues.kind_get(a.kernel, lues.Kind(kind))
}

// The I/O worker's answers, then whose generation moved. True when a plugin latched.
plug_pump :: proc(a: ^App) -> (latched: bool) {
    return lues.kernel_frame(a.kernel)
}

plug_doc :: proc(id: store.Id) -> abi.Doc_Handle {
    return lues.doc_handle(id)
}

store_id :: proc(doc: abi.Doc_Handle) -> store.Id {
    return lues.doc_id(doc)
}

// --- the hooks ---

@(rodata)
HOOKS := lues.Hooks {
    say = proc(k: ^lues.Kernel, text: string) {
        a := app_of(k)
        message_set(&a, text)
    },
    side_make = proc(k: ^lues.Kernel, id: docs.Id, gen: u64) -> rawptr {
        a := app_of(k)
        return side_make(&a, id)
    },
    side_free = proc(k: ^lues.Kernel, side: rawptr) {
        side_free((^Side_Box)(side))
    },
    land = proc(k: ^lues.Kernel, id: docs.Id, side: rawptr, landed: bool) {
        store.store_land(&k.store, id, side, landed)
    },
    drained = proc(k: ^lues.Kernel) {
        a := app_of(k)
        a.settled += len(docs.store_landed(&k.store)) + store.store_drained(&k.store)
    },
    check = proc(k: ^lues.Kernel) -> bool {
        return store.store_check(&k.store)
    },
    doc_open = proc(k: ^lues.Kernel, kind: lues.Kind) -> (docs.Id, bool) {
        a := app_of(k)
        id := store.store_open(a.docs)
        d := desc.new_from({ctx = kind_ctx(&a, input.Kind(kind)), kind = input.Kind(kind), selection = .Line})
        store.store_describe(a.docs, id, d)
        desc.release(d)
        return id, true
    },
    doc_close = proc(k: ^lues.Kernel, id: docs.Id) {
        a := app_of(k)
        doc_close(&a, id)
    },
    kind_ctx = proc(k: ^lues.Kernel, name: string) -> (ctx: u32, ok: bool) {
        c, known := input.ctx_named(name if name != "" else "surface")
        return u32(c), known && c != .Global
    },
    unregister = proc(k: ^lues.Kernel, r: lues.Record) {
        a := app_of(k)
        if r.tag == RECORD_VIEW {
            delete_key(&a.viewers, r.idx)
            views_dirty(&a)
        }
    },
    // A kind or a command may be named by a row, so both files are read again now the names
    // resolve; one that resolves to nothing falls through to the row underneath.
    changed = proc(k: ^lues.Kernel) {
        a := app_of(k)
        config_sync(&a)
        binds_sync(&a)
        views_dirty(&a)
    },
    bind_held = proc(k: ^lues.Kernel, ctx, chord: string) -> (held: string, hold: lues.Bind_Hold) {
        a := app_of(k)
        if name, taken := binds_held(&a, ctx, chord); taken {
            return name, .Taken
        }
        if name, wider := binds_shadowed(&a, ctx, chord); wider {
            return name, .Shadowed
        }
        return "", .Free
    },
    // The descriptor staged by `describe`, and what oket needs to place the carets.
    submit_side = proc(k: ^lues.Kernel, i: int, id: docs.Id, gen: u64, splices: []docs.Splice,
                       flags: lues.Submit_Flags) -> rawptr {
        a := app_of(k)
        key := Staged{lues.self_handle(k, i), id}
        d := a.staged[key]
        delete_key(&a.staged, key)
        defer desc.release(d)
        edits := make([]txt.Edit, len(splices), context.temp_allocator)
        for sp, n in splices {
            edits[n] = {sp.lo, sp.hi, string(sp.text), 0, sp.tag}
        }
        return store.store_side(a.docs, id, gen, edits, d, .Forget in flags)
    },
}

app_of :: proc(k: ^lues.Kernel) -> App {
    return {state = (^State)(k.user)}
}

// --- oket's tail of the api ---

// lues's guard, and the host context: an arm allocates on oket's allocator.
@(private = "file")
tail :: proc "contextless" (api: ^abi.Api, self: abi.Self) -> (a: App, k: ^Kernel, i: int, ok: bool) {
    lk: ^lues.Kernel
    lk, i, ok = lues.api_kernel(api, self)
    if ok {
        k = (^Kernel)(lk)
        a = {state = (^State)(k.user)}
    }
    return
}

// Staged, so it lands at the generation of the submit it rides (plug.Api.describe).
@(private = "file")
api_describe :: proc "c" (api: ^abi.Api, self: abi.Self, doc: abi.Doc_Handle, d: ^plug.Descriptor) {
    a, k, _, ok := tail(api, self)
    defer lues.api_done()
    if !ok || d == nil {
        return
    }
    context = k.host
    key := Staged{self, store_id(doc)}
    desc.release(a.staged[key])
    a.staged[key] = plug_desc_take(&a, key.doc, d)
}

@(private = "file")
api_reveal :: proc "c" (api: ^abi.Api, self: abi.Self, doc: abi.Doc_Handle, lo, hi: uint,
                        at: plug.Reveal) {
    a, k, _, ok := tail(api, self)
    defer lues.api_done()
    if !ok {
        return
    }
    context = k.host
    reveal_span(&a, store_id(doc), int(lo), int(hi), at)
}

// Queued on the doc: the submit it rides has not landed yet (store_cursors).
@(private = "file")
api_cursors :: proc "c" (api: ^abi.Api, self: abi.Self, doc: abi.Doc_Handle,
                         curs: [^]plug.Cursor, n: uint, primary: uint) {
    a, k, _, ok := tail(api, self)
    defer lues.api_done()
    if !ok || curs == nil || n == 0 {
        return
    }
    context = k.host
    set := transmute([]txt.Cursor)curs[:n]
    store.store_cursors(a.docs, store_id(doc), set, int(min(primary, n - 1)))
}

// Registering twice replaces, with one ledger record.
@(private = "file")
api_register_view :: proc "c" (api: ^abi.Api, self: abi.Self, fn: plug.View_Fn) {
    a, k, i, ok := tail(api, self)
    defer lues.api_done()
    if !ok || fn == nil {
        return
    }
    context = k.host
    if i not_in a.viewers {
        lues.ledger_add(k, i, RECORD_VIEW, i)
    }
    a.viewers[i] = fn
    views_dirty(&a)
}

@(private = "file")
api_world :: proc "c" (api: ^abi.Api, self: abi.Self) -> ^plug.World {
    a, k, _, ok := tail(api, self)
    defer lues.api_done()
    if !ok {
        return nil
    }
    context = k.host
    return &world_make(&a).world
}

@(private = "file")
api_world_release :: proc "c" (api: ^abi.Api, self: abi.Self, w: ^plug.World) {
    _, k, _, ok := tail(api, self)
    defer lues.api_done()
    if !ok || w == nil {
        return
    }
    context = k.host
    world_free((^Plug_World)(w))
}

// --- a view stage, through the fault net (§10) ---

@(private = "file")
View_Call :: struct {
    fn:  plug.View_Fn,
    at:  ^abi.At,
    out: ^plug.View_Out,
}

// False: it faulted and is unloaded.
plug_view_run :: proc(a: ^App, i: int, at: ^abi.At, out: ^plug.View_Out) -> (code: i32, ok: bool) {
    call := View_Call{a.viewers[i], at, out}
    r: lues.Ret
    r, ok = lues.dispatch(a.kernel, i, {what = .App, arg = &call, app = proc(api: ^abi.Api, self: abi.Self, data: rawptr) -> i32 {
        c := (^View_Call)(data)
        return c.fn(api, self, c.at, c.out)
    }})
    return r.code, ok
}

// The live plugin with a stage registered under `name`. A `view =` line naming a plugin that
// is not installed is a config file ahead of the machine, not an error.
plug_view_of :: proc(a: ^App, name: string) -> (int, bool) {
    for i in a.viewers {
        if a.kernel.plugs[i].name == name {
            return i, true
        }
    }
    return 0, false
}

quarantined :: proc(a: ^App, name: string) -> bool {
    return lues.quarantined(a.kernel, name)
}

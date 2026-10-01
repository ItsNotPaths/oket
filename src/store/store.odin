package store

import "base:runtime"
import "core:slice"
import "lues:docs"
import "lues:pt"
import "../desc"
import "../txt"

// lues's document table, and oket's half of each document: its carets (txt.Doc), its descriptor
// and a caret set waiting on the drain. That half hangs off docs.Doc.side; what an oket submit
// carries for it hangs off Txn.side and lands in `land`.
//
// Reads do not come through here. A caller takes a snapshot and reads it directly (§6). Writes
// queue, and store_drain applies them, so the generation moves at exactly one place.

Store :: docs.Store
Id :: docs.Id
Producer :: docs.Producer
Key :: docs.Key
Span :: docs.Span_Run
Spans :: docs.Spans
SPAN_MAX :: docs.SPAN_MAX

// A run's attrs and channels cross as shape's sets; the bits are the same.
#assert(int(docs.Chan.Fg) == int(desc.Chan.Fg) && int(docs.Chan.Bg) == int(desc.Chan.Bg) &&
        int(docs.Chan.Attrs) == int(desc.Chan.Attrs) && len(docs.Chan) == len(desc.Chan))

// docs.Doc.side, on the heap: the drain and the kernel hold ^txt.Doc across calls.
@(private)
Extra :: struct {
    doc:          txt.Doc,
    desc:         ^desc.Descriptor,
    // The set the owner asked for, applied at the drain WITH the transaction it rides
    // (store_cursors). Empty is nobody asking; `curs_tag` is that transaction, 0 for a bare move.
    curs:         [dynamic]txt.Cursor,
    curs_primary: int,
    curs_tag:     u64,
}

// Txn.side. Owns its edits' text and a descriptor reference.
@(private)
Txn_Side :: struct {
    edits: []txt.Edit, // doc_fuse's, against the doc at `gen`
    gen:   u64,
    desc:  ^desc.Descriptor, // nil = leave the descriptor as it stands
    // The carets were put where they are by NAVIGATION, so they stay on their rows
    // (cursor_policy), and there is nothing of the user's to undo.
    regen: bool,
}

store_destroy :: proc(s: ^Store) {
    for slot in s.slots {
        if slot.doc != nil {
            extra_free((^Extra)(slot.doc.side))
        }
    }
    caller := Caller{s, context}
    docs.store_destroy(s, land_as_caller, &caller)
}

store_open :: proc(s: ^Store, text := "") -> Id {
    id := docs.store_open(s)
    core := docs.store_doc(s, id)
    x := new(Extra)
    txt.doc_init(&x.doc, core)
    if text != "" {
        txt.doc_set_text(&x.doc, text)
    }
    x.desc = desc.new_from(desc.DEFAULT)
    core.side = x
    return id
}

// Every Id handed out for this document stops resolving. A snapshot someone still holds is
// unaffected (§6).
store_close :: proc(s: ^Store, id: Id) -> bool {
    x := extra(s, id)
    if x == nil {
        return false
    }
    extra_free(x)
    return docs.store_close(s, id)
}

store_is_open :: proc(s: ^Store, id: Id) -> bool {
    _, ok := docs.store_resolve(s, id)
    return ok
}

// The kernel's own mutable handle, and nothing outside the kernel gets one (§12).
store_doc :: proc(s: ^Store, id: Id) -> ^txt.Doc {
    x := extra(s, id)
    return &x.doc if x != nil else nil
}

// The terminal's colours, at one point in its own pump. A plugin publishes through submit.
store_spans_publish :: proc(s: ^Store, id: Id, pub: Spans) -> bool {
    slot := docs.store_resolve(s, id) or_return
    return docs.spans_apply(slot, pub)
}

store_spans :: proc(s: ^Store, id: Id, lo, hi: int, order: []Producer,
                    alloc := context.temp_allocator) -> []Span {
    return docs.spans_read(s, id, lo, hi, order, alloc)
}

store_spans_forget :: proc(s: ^Store, who: Producer) {
    docs.spans_forget(s, who)
}

// A reference the caller owns and must release.
store_descriptor :: proc(s: ^Store, id: Id) -> ^desc.Descriptor {
    x := extra(s, id)
    if x == nil {
        return nil
    }
    desc.retain(x.desc)
    return x.desc
}

// A fresh document's baseline, with no transaction: nothing has read it yet.
store_describe :: proc(s: ^Store, id: Id, d: ^desc.Descriptor) {
    if x := extra(s, id); x != nil {
        desc.retain(d)
        desc.release(x.desc)
        x.desc = d
    }
}

store_ids :: proc(s: ^Store, alloc := context.temp_allocator) -> []Id {
    return docs.store_ids(s, alloc)
}

store_gen :: proc(s: ^Store, id: Id) -> (gen: u64, ok: bool) {
    return docs.store_gen(s, id)
}

store_snapshot :: proc(s: ^Store, id: Id) -> ^pt.Snapshot {
    d := docs.store_doc(s, id)
    return docs.doc_snapshot(d) if d != nil else nil
}

// Queue a transaction; applied at the next store_drain, or dropped there if the document moved
// first. The tag names it in store_landed.
store_submit :: proc(s: ^Store, id: Id, gen: u64, edits: []txt.Edit,
                     d: ^desc.Descriptor = nil, spans: Maybe(Spans) = nil,
                     regen := false) -> (tag: u64) {
    side := store_side(s, id, gen, edits, d, regen)
    if side == nil {
        return docs.store_submit(s, id, gen, nil, spans) // dropped at the drain
    }
    t := (^Txn_Side)(side)
    return docs.store_submit(s, id, gen, txt.doc_splices(t.edits), spans, side,
                             .Forget if regen else .Step)
}

// What `store_land` needs of a submit, fused against the doc as it stands. nil for a closed doc.
store_side :: proc(s: ^Store, id: Id, gen: u64, edits: []txt.Edit, d: ^desc.Descriptor,
                   regen: bool) -> rawptr {
    x := extra(s, id)
    if x == nil {
        return nil
    }
    t := new(Txn_Side)
    t^ = {edits = slice.clone(txt.doc_fuse(&x.doc, edits)), gen = gen, desc = d, regen = regen}
    for &e in t.edits {
        e.text = string(slice.clone(transmute([]u8)e.text))
    }
    if d != nil {
        desc.retain(d)
    }
    return t
}

// Where the cursors go when this drain is done (CURSORS.md §4). Copied.
//
// TOGETHER MEANS BOTH WAYS. The set was measured against text a pending transaction is about
// to write, so it rides that transaction's tag: if the write is dropped, the carets go with it.
// A set with nothing pending is a bare move: it always lands and never moves the generation.
store_cursors :: proc(s: ^Store, id: Id, curs: []txt.Cursor, primary: int) {
    x := extra(s, id)
    if x == nil || len(curs) == 0 {
        return
    }
    clear(&x.curs)
    append(&x.curs, ..curs)
    x.curs_primary = clamp(primary, 0, len(curs) - 1)
    x.curs_tag = 0
    #reverse for t in s.pending {
        if t.id == id {
            x.curs_tag = t.tag
            break
        }
    }
}

store_landed :: proc(s: ^Store) -> []u64 {
    return docs.store_landed(s)
}

// The one point in the frame writes land (§6).
store_drain :: proc(s: ^Store) -> (applied, stale: int) {
    caller := Caller{s, context}
    applied, stale = docs.store_drain(s, land_as_caller, &caller)
    applied += store_drained(s)
    return
}

// After a drain's splices, the caret sets: one is written against the text they land. Each
// counts as applied, so the caller re-reads the caret; the generation does not move.
store_drained :: proc(s: ^Store) -> (applied: int) {
    for slot in s.slots {
        if slot.doc == nil {
            continue
        }
        x := (^Extra)(slot.doc.side)
        if len(x.curs) == 0 {
            continue
        }
        tag := x.curs_tag
        x.curs_tag = 0
        if tag == 0 || slice.contains(s.landed[:], tag) {
            txt.doc_commit(&x.doc, nil, {policy = .Set, set = x.curs[:], primary = x.curs_primary},
                           x.desc.tab_width)
            applied += 1
        }
        clear(&x.curs)
    }
    return
}

// §10's invariant checks, run after each plugin dispatch. O(1) per open document.
store_check :: proc(s: ^Store) -> bool {
    if !docs.store_check(s) {
        return false
    }
    for slot in s.slots {
        if slot.doc != nil && !txt.doc_check(&(^Extra)(slot.doc.side).doc) {
            return false
        }
    }
    return true
}

// --- internals ---

// lues's drain runs a Land on the store's allocator; a side is the caller's, so land runs in
// the caller's context.
@(private = "file")
Caller :: struct {
    s:   ^Store,
    ctx: runtime.Context,
}

@(private = "file")
land_as_caller :: proc(user: rawptr, id: docs.Id, side: rawptr, landed: bool) {
    c := (^Caller)(user)
    context = c.ctx
    store_land(c.s, id, side, landed)
}

@(private)
extra :: proc(s: ^Store, id: Id) -> ^Extra {
    d := docs.store_doc(s, id)
    return (^Extra)(d.side) if d != nil else nil
}

@(private = "file")
extra_free :: proc(x: ^Extra) {
    txt.doc_destroy(&x.doc)
    desc.release(x.desc)
    delete(x.curs)
    free(x)
}

// Every Txn_Side ends here, landed or dropped.
store_land :: proc(s: ^Store, id: docs.Id, side: rawptr, landed: bool) {
    t := (^Txn_Side)(side)
    // Not looked up when dropped: store_destroy frees the docs before the pending.
    if x := extra(s, id) if landed else nil; x != nil {
        txt.doc_landed(&x.doc, t.edits, t.gen, !t.regen, {policy = cursor_policy(x, t)})
        if t.desc != nil {
            desc.release(x.desc)
            desc.retain(t.desc)
            x.desc = t.desc
        }
    }
    for e in t.edits {
        delete(e.text)
    }
    delete(t.edits)
    desc.release(t.desc)
    free(t)
}

// A REGENERATION, not an edit: a browser rewrites its rows to expand a directory, and the
// carets there are navigation. .Pin leaves them on their rows; .Follow collapses them onto the
// splice the way the editor must (§5, §6). A document that takes no typing only regenerates.
@(private = "file")
cursor_policy :: proc(x: ^Extra, t: ^Txn_Side) -> txt.Cursor_Policy {
    if x.desc != nil && x.desc.editable && !t.regen {
        return .Follow
    }
    return .Pin
}

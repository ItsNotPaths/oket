package store

import "core:strings"
import "../desc"
import "../txt"

// The kernel's table of open documents, and the one place a write happens.
//
// Reads do not come through here. A caller takes a txt.Snapshot and reads it directly — no
// call back into the kernel, no copy of the text, no lock (§6). That is the asymmetry the
// whole concurrency model rests on: many readers at whatever generation they took, one writer
// at one point in the frame.
//
// Writes are transactions. They queue, and store_drain applies them, so the generation moves
// at exactly one place and nobody ever reads a half-applied edit.

// A slot index plus the seq that slot carried when the document was opened. Closing bumps the
// seq, so an Id kept across a close resolves to nothing instead of to whoever took the slot
// next — the failure a bare index turns into silent corruption.
Id :: struct {
    slot: u32,
    seq:  u32,
}

Store :: struct {
    slots:   [dynamic]Slot,
    free:    [dynamic]u32, // slots whose document closed, ready to be taken again
    pending: [dynamic]Txn,
}

// The Doc is heap-allocated so growing `slots` cannot move it: the drain and the kernel both
// hold ^txt.Doc across calls.
@(private)
Slot :: struct {
    seq:  u32,
    doc:  ^txt.Doc, // nil = closed
    desc: ^desc.Descriptor,
}

// One transaction against the generation its author read. Owns its edits and their text, and
// the descriptor it publishes, until the drain applies it. Spans arrive at stage 11.
Txn :: struct {
    id:    Id,
    gen:   u64,
    edits: []txt.Edit,
    desc:  ^desc.Descriptor, // nil = leave the descriptor as it stands
}

store_destroy :: proc(s: ^Store) {
    for &slot in s.slots {
        if slot.doc != nil {
            txt.doc_destroy(slot.doc)
            free(slot.doc)
            desc.release(slot.desc)
        }
    }
    for t in s.pending {
        txn_destroy(t)
    }
    delete(s.slots)
    delete(s.free)
    delete(s.pending)
    s^ = {}
}

store_open :: proc(s: ^Store, text := "") -> Id {
    slot: u32
    if len(s.free) > 0 {
        slot = pop(&s.free)
    } else {
        slot = u32(len(s.slots))
        append(&s.slots, Slot{})
    }
    d := new(txt.Doc)
    txt.doc_init(d)
    if text != "" {
        txt.doc_set_text(d, text)
    }
    s.slots[slot].doc = d
    s.slots[slot].desc = desc.new_from(desc.DEFAULT)
    return Id{slot, s.slots[slot].seq}
}

// Every Id handed out for this document stops resolving. A snapshot someone still holds is
// unaffected: it owns its own reference to the bytes and outlives the document (§6).
store_close :: proc(s: ^Store, id: Id) -> bool {
    slot := resolve(s, id) or_return
    txt.doc_destroy(slot.doc)
    free(slot.doc)
    desc.release(slot.desc)
    slot.doc = nil
    slot.desc = nil
    slot.seq += 1
    append(&s.free, id.slot)
    return true
}

store_is_open :: proc(s: ^Store, id: Id) -> bool {
    _, ok := resolve(s, id)
    return ok
}

// The kernel's own mutable handle, and nothing outside the kernel gets one (§12). A plugin
// reads a snapshot and writes through store_submit.
store_doc :: proc(s: ^Store, id: Id) -> ^txt.Doc {
    slot, ok := resolve(s, id)
    return ok ? slot.doc : nil
}

// A reference the caller owns and must release, taken at the same point as the snapshot it
// pairs with. Immutable, so it stays readable however the document moves (§5).
store_descriptor :: proc(s: ^Store, id: Id) -> ^desc.Descriptor {
    slot, ok := resolve(s, id)
    if !ok {
        return nil
    }
    desc.retain(slot.desc)
    return slot.desc
}

store_gen :: proc(s: ^Store, id: Id) -> (gen: u64, ok: bool) {
    slot := resolve(s, id) or_return
    return slot.doc.gen, true
}

// A reference the caller owns and must release. It stays readable however the document moves
// afterwards, closing included; the generation it carries is what a later write rebases on.
store_snapshot :: proc(s: ^Store, id: Id) -> ^txt.Snapshot {
    slot, ok := resolve(s, id)
    return ok ? txt.doc_snapshot(slot.doc) : nil
}

// Queue a transaction. The text is cloned, so the caller's buffer may die the moment this
// returns. Applied at the next store_drain, or dropped there if the document moved first.
store_submit :: proc(s: ^Store, id: Id, gen: u64, edits: []txt.Edit, d: ^desc.Descriptor = nil) {
    owned := make([]txt.Edit, len(edits))
    for e, i in edits {
        owned[i] = e
        owned[i].text = strings.clone(e.text)
    }
    if d != nil {
        desc.retain(d)
    }
    append(&s.pending, Txn{id, gen, owned, d})
}

// The one point in the frame writes land (§6). A transaction whose document has moved since it
// was written is dropped whole rather than merged: its author re-reads and retries, and §7's
// client library is where that loop lives so no plugin author writes one.
store_drain :: proc(s: ^Store) -> (applied, stale: int) {
    for t in s.pending {
        defer txn_destroy(t)
        slot, ok := resolve(s, t.id)
        if !ok || slot.doc.gen != t.gen {
            stale += 1
            continue
        }
        txt.doc_commit(slot.doc, t.edits)
        if t.desc != nil {
            desc.release(slot.desc)
            desc.retain(t.desc)
            slot.desc = t.desc
        }
        applied += 1
    }
    clear(&s.pending)

    // Amortised housekeeping, off the edit path and after the generation has settled. Anyone
    // holding a snapshot keeps the arena compaction leaves behind, so this is safe here and
    // would not be mid-transaction.
    for &slot in s.slots {
        if slot.doc != nil {
            txt.doc_maintain(slot.doc)
        }
    }
    return
}

// --- internals ---

@(private = "file")
resolve :: proc(s: ^Store, id: Id) -> (^Slot, bool) {
    if int(id.slot) >= len(s.slots) {
        return nil, false
    }
    slot := &s.slots[id.slot]
    if slot.doc == nil || slot.seq != id.seq {
        return nil, false
    }
    return slot, true
}

@(private = "file")
txn_destroy :: proc(t: Txn) {
    for e in t.edits {
        delete(e.text)
    }
    delete(t.edits)
    desc.release(t.desc)
}

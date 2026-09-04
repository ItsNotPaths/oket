package store

import "core:slice"
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
    // Tags of the transactions the last drain APPLIED, and the counter they come from. A
    // submitter that has to know whether its own write landed cannot read it off the
    // generation: a foreign write against the same generation moves it either way.
    landed:  [dynamic]u64,
    tag:     u64,
}

// The Doc is heap-allocated so growing `slots` cannot move it: the drain and the kernel both
// hold ^txt.Doc across calls.
@(private)
Slot :: struct {
    seq:   u32,
    doc:   ^txt.Doc, // nil = closed
    desc:  ^desc.Descriptor,
    seen:  u64, // the highest generation store_check has seen; it may never go backwards
    spans: [dynamic]Bucket, // one bucket per publisher (spans.odin)
    // Where the document's owner asked point to be, applied at the drain so it lands WITH the
    // transaction it belongs to (store_point). -1 is nobody asking, and `point_tag` is the
    // transaction it rides on, or 0 for a bare move with no write behind it.
    point:     int,
    point_tag: u64,
}

// One transaction against the generation its author read. Owns its edits and their text, the
// descriptor it publishes and the spans it publishes, until the drain applies it.
//
// All three ride together on purpose: the runs and the text they cover land at ONE generation,
// so nothing ever paints a colour against bytes it was not measured over.
Txn :: struct {
    id:    Id,
    gen:   u64,
    tag:   u64,
    edits: []txt.Edit,
    desc:  ^desc.Descriptor, // nil = leave the descriptor as it stands
    spans: Maybe(Spans),     // nil = leave every publisher's runs as they stand
    // The carets here were put where they are by NAVIGATION, so leave them on their rows
    // (cursor_policy). Said by the author, because the offsets cannot say it.
    regen: bool,
}

store_destroy :: proc(s: ^Store) {
    for &slot in s.slots {
        if slot.doc != nil {
            txt.doc_destroy(slot.doc)
            free(slot.doc)
            desc.release(slot.desc)
        }
        for &b in slot.spans {
            delete(b.list)
        }
        delete(slot.spans)
    }
    for t in s.pending {
        txn_destroy(t)
    }
    delete(s.slots)
    delete(s.free)
    delete(s.pending)
    delete(s.landed)
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
    s.slots[slot].seen = 0 // a new document, so store_check's high-water mark starts again
    s.slots[slot].point = -1
    s.slots[slot].point_tag = 0
    for &b in s.slots[slot].spans {
        clear(&b.list) // the slot may be a reused one, and its colours were somebody else's
    }
    return Id{slot, s.slots[slot].seq}
}

// Every Id handed out for this document stops resolving. A snapshot someone still holds is
// unaffected: it owns its own reference to the bytes and outlives the document (§6).
store_close :: proc(s: ^Store, id: Id) -> bool {
    slot := resolve(s, id) or_return
    txt.doc_destroy(slot.doc)
    free(slot.doc)
    desc.release(slot.desc)
    for &b in slot.spans {
        clear(&b.list)
    }
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

// The same privilege for the style layers: the terminal writes its text through store_doc and
// its colours through here, at one point in its own pump. A plugin has neither and publishes
// through store_submit, where the drain lands the runs and the bytes at one generation.
store_spans_publish :: proc(s: ^Store, id: Id, pub: Spans) -> bool {
    slot := resolve(s, id) or_return
    return spans_apply(slot, pub)
}

// A reference the caller owns and must release, taken at the same point as the snapshot it
// pairs with. Immutable, so it stays readable however the document moves (§5).
//
// Every reader comes through here, which is what lets the spans be brought up to the text
// LAZILY (fields.odin): no caller can be handed a field the document has moved out from under,
// and a document nobody is reading pays nothing.
store_descriptor :: proc(s: ^Store, id: Id) -> ^desc.Descriptor {
    slot, ok := resolve(s, id)
    if !ok {
        return nil
    }
    fields_follow(slot)
    desc.retain(slot.desc)
    return slot.desc
}

// Every open document, in slot order. What a watcher is told about (§7): a plugin that draws
// nothing has no instance of its own, so this is the only way it hears that work exists.
store_ids :: proc(s: ^Store, alloc := context.temp_allocator) -> []Id {
    out := make([dynamic]Id, 0, len(s.slots), alloc)
    for slot, i in s.slots {
        if slot.doc != nil {
            append(&out, Id{u32(i), slot.seq})
        }
    }
    return out[:]
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
//
// The tag it answers names this transaction in store_landed, for a caller that has to tell its
// own write from somebody else's. A caller that does not care ignores it.
store_submit :: proc(s: ^Store, id: Id, gen: u64, edits: []txt.Edit,
                     d: ^desc.Descriptor = nil, spans: Maybe(Spans) = nil,
                     regen := false) -> (tag: u64) {
    owned := make([]txt.Edit, len(edits))
    for e, i in edits {
        owned[i] = e
        owned[i].text = strings.clone(e.text)
    }
    if d != nil {
        desc.retain(d)
    }
    kept := spans
    if pub, publishing := spans.?; publishing {
        pub.list = slice.clone(pub.list)
        kept = pub
    }
    s.tag += 1
    append(&s.pending, Txn{id, gen, s.tag, owned, d, kept, regen})
    return s.tag
}

// Where point goes when this drain is done (§5). The kernel owns the cursors, so this is not
// how a document is navigated: it is for the owner whose submit is about to delete the row
// point is standing on, and the two have to land together.
//
// TOGETHER MEANS BOTH WAYS. The offset was measured against text a pending transaction is about
// to write, so it rides that transaction's tag: if the write is dropped at the drain for having
// lost the race, the caret it was measured for is dropped with it rather than jumping into text
// that never arrived. A point asked for with nothing pending is a bare move and always lands.
store_point :: proc(s: ^Store, id: Id, off: int) {
    slot, ok := resolve(s, id)
    if !ok {
        return
    }
    slot.point = max(off, 0)
    slot.point_tag = 0
    #reverse for t in s.pending {
        if t.id == id {
            slot.point_tag = t.tag
            break
        }
    }
}

// Which transactions the last drain applied. Valid until the next one.
store_landed :: proc(s: ^Store) -> []u64 {
    return s.landed[:]
}

// The one point in the frame writes land (§6). A transaction whose document has moved since it
// was written is dropped whole rather than merged: its author re-reads and retries, and §7's
// client library is where that loop lives so no plugin author writes one.
store_drain :: proc(s: ^Store) -> (applied, stale: int) {
    clear(&s.landed)
    for t in s.pending {
        defer txn_destroy(t)
        slot, ok := resolve(s, t.id)
        if !ok || slot.doc.gen != t.gen {
            stale += 1
            continue
        }
        txt.doc_commit(slot.doc, t.edits, {policy = cursor_policy(slot, t)})
        if t.regen {
            // REGEN's other half (Submit_Flags): derived text holds nothing of the user's to
            // take back, so the log goes — what was typed before it is still in the text.
            txt.doc_forget_undo(slot.doc)
        }
        if pub, publishing := t.spans.?; publishing {
            spans_apply(slot, pub)
        }
        if t.desc != nil {
            // A published descriptor was written against the text this transaction just landed,
            // so its spans are already true: acking is what stops fields.odin shifting them a
            // second time for the same splice.
            txt.doc_changes_ack(slot.doc, .Fields)
            desc.release(slot.desc)
            desc.retain(t.desc)
            slot.desc = t.desc
        }
        append(&s.landed, t.tag)
        applied += 1
    }
    clear(&s.pending)

    // After the splices, because the offset was written against the text they land: an owner
    // that rewrites its rows and says where point goes is describing the document it just made.
    // It counts as APPLIED, which is what makes the caller re-read the caret and keep it on
    // screen — a point that moved with no splice behind it still moved.
    for &slot in s.slots {
        if slot.doc == nil || slot.point < 0 {
            continue
        }
        want := slot.point
        tag := slot.point_tag
        slot.point, slot.point_tag = -1, 0
        if tag != 0 && !slice.contains(s.landed[:], tag) {
            continue // its transaction was dropped, so the offset describes text nobody wrote
        }
        txt.doc_reset_cursor(slot.doc, txt.doc_pos(slot.doc, min(want, txt.doc_len(slot.doc))))
        applied += 1
    }

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

// §10's invariant checks, run after each plugin dispatch. Every arm is O(1) per open
// document, which is what makes it cheap enough to leave on in release: a document's magic
// word, its piece list's running total, and a generation that only ever goes forwards. Who is
// to blame is the caller's question: this only says that somebody is.
store_check :: proc(s: ^Store) -> bool {
    for &slot in s.slots {
        if slot.doc == nil {
            continue
        }
        if !txt.doc_check(slot.doc) || slot.doc.gen < slot.seen {
            return false
        }
        slot.seen = slot.doc.gen
    }
    return true
}

// --- internals ---

// A REGENERATION, not an edit: a browser rewrites its rows to expand a directory, and the
// carets there are navigation rather than the place a keystroke landed. .Pin leaves them on
// their rows, instead of collapsing onto the splice the way .Follow must for the editor (§5,
// §6).
//
// Two things answer it. A document that takes no typing has nothing in it a keystroke put
// there, so every write to one is a regeneration. A document that takes typing AND rewrites
// itself — a browser you rename in — is per TRANSACTION, and the transaction has to SAY so: the
// offsets cannot, because replacing a whole document and replacing a whole selection are the
// same two numbers.
@(private = "file")
cursor_policy :: proc(slot: ^Slot, t: Txn) -> txt.Cursor_Policy {
    if slot.desc != nil && slot.desc.editable && !t.regen {
        return .Follow
    }
    return .Pin
}

@(private)
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
    if pub, publishing := t.spans.?; publishing {
        delete(pub.list)
    }
}

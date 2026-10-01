package txt

import "base:intrinsics"
import "core:slice"
import "core:unicode/utf8"
import "lues:docs"

// The steps and their replay are lues's (docs.Doc.undo). txt adds the carets each step restores,
// packed into Step.before and Step.after, and the coalescing: consecutive single-character
// inserts join one step, broken by whitespace, a caret move or any other edit.

// What a document ARRIVED with is not an edit. A load goes through the same funnel a keystroke
// does, so without this the first undo takes a freshly opened buffer back to empty.
doc_forget_undo :: proc(d: ^Doc) {
    docs.doc_forget_undo(d.core)
}

// `cur` is the commit's cursor policy (doc.odin), and the step records where it left them, so
// redo lands there too.
doc_commit :: proc(d: ^Doc, edits: []Edit, cur := Commit{}, tab := 4) -> bool {
    return doc_land(d, edits, .Step, cur, tab)
}

// Read across an edit, it says whether that edit opened a step or coalesced into the one before.
doc_steps_made :: proc(d: ^Doc) -> int {
    return d.made
}

// Replays the step's inverse and restores the pre-edit cursors.
doc_undo :: proc(d: ^Doc, tab := 4) -> bool {
    if len(d.undo) == 0 {
        return false
    }
    if d.sink.write != nil {
        #reverse for batch in d.undo[len(d.undo) - 1].batches {
            #reverse for op in batch {
                d.sink.write(d.sink.user, op.inv_at, len(op.inserted), string(op.removed))
            }
        }
    }
    step := docs.doc_undo(d.core)
    set, primary := cursors_unpack(step.before)
    doc_set_cursors(d, set, primary, tab)
    doc_changes_ack(d, .Carets)
    return true
}

// Replays the step forward and restores the post-edit cursors.
doc_redo :: proc(d: ^Doc, tab := 4) -> bool {
    if len(d.redo) == 0 {
        return false
    }
    if d.sink.write != nil {
        for batch in d.redo[len(d.redo) - 1].batches {
            #reverse for op in batch {
                d.sink.write(d.sink.user, op.at, len(op.removed), string(op.inserted))
            }
        }
    }
    step := docs.doc_redo(d.core)
    set, primary := cursors_unpack(step.after)
    doc_set_cursors(d, set, primary, tab)
    doc_changes_ack(d, .Carets)
    return true
}

// --- internals ---

// lues just opened the top step for `fused`. It takes its carets, or joins the step before.
@(private)
undo_landed :: proc(d: ^Doc, fused: []Edit, before: []u8) {
    top := &d.undo[len(d.undo) - 1]
    after := cursors_pack(d)
    if !coalesces(d, fused, before) {
        top.before, top.after = before, after
        d.made += 1
        return
    }
    prev := &d.undo[len(d.undo) - 2]
    append(&prev.batches, ..top.batches[:])
    delete(prev.after, d.alloc)
    prev.after = after
    delete(top.batches)
    delete(before, d.alloc)
    pop(&d.undo)
}

// [primary][the set], on the doc's allocator: lues frees a step's bytes.
@(private)
cursors_pack :: proc(d: ^Doc) -> []u8 {
    out := make([]u8, size_of(int) + len(d.cursors) * size_of(Cursor), d.alloc)
    intrinsics.unaligned_store((^int)(raw_data(out)), d.primary)
    copy(out[size_of(int):], slice.to_bytes(d.cursors[:]))
    return out
}

@(private = "file")
cursors_unpack :: proc(b: []u8) -> (set: []Cursor, primary: int) {
    if len(b) < size_of(int) {
        return
    }
    return slice.reinterpret([]Cursor, b[size_of(int):]), intrinsics.unaligned_load((^int)(raw_data(b)))
}

// Whitespace, or a bracket/quote delimiter. After one is typed the step is sealed.
@(private = "file")
is_undo_break :: proc(r: rune) -> bool {
    switch r {
    case ' ', '\t', '\n', '(', ')', '[', ']', '{', '}', '"', '\'', '`':
        return true
    }
    return false
}

// A single-character insert landing where the step before left off, whose last inserted
// character was not a break char.
@(private = "file")
coalesces :: proc(d: ^Doc, fused: []Edit, before: []u8) -> bool {
    if len(d.undo) < 2 || !is_char_insert(fused) {
        return false
    }
    prev := &d.undo[len(d.undo) - 2]
    return cursors_match(prev.after, before) && step_open(prev)
}

// A keystroke fans out to every cursor as one character, so a batch coalesces when ALL its
// edits are single-char inserts.
@(private = "file")
is_char_insert :: proc(fused: []Edit) -> bool {
    n := 0
    for e in fused {
        if edit_is_noop(e) {
            continue
        }
        if e.hi != e.lo || utf8.rune_count_in_string(e.text) != 1 {
            return false
        }
        n += 1
    }
    return n > 0
}

// Still open if its last edit inserted a non-break character.
@(private = "file")
step_open :: proc(s: ^docs.Step) -> bool {
    if len(s.batches) == 0 {
        return false
    }
    b := s.batches[len(s.batches) - 1]
    if len(b) == 0 {
        return false
    }
    op := b[len(b) - 1]
    if len(op.removed) != 0 || len(op.inserted) == 0 {
        return false
    }
    last, _ := utf8.decode_last_rune(op.inserted)
    return !is_undo_break(last)
}

@(private = "file")
cursors_match :: proc(a, b: []u8) -> bool {
    x, _ := cursors_unpack(a)
    y, _ := cursors_unpack(b)
    if len(x) != len(y) {
        return false
    }
    for c, i in x {
        if c.head != y[i].head || c.anchor != y[i].anchor {
            return false
        }
    }
    return true
}

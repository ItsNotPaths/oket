package store

import "core:slice"
import "../desc"
import "../txt"

// FIELDS RIDE THE TEXT (§5).
//
// A field is a span of a line, so text that moves under it has to take it along. Without this
// the spans are only true for the generation they were published at: type one character into a
// listing and every link on that line points at bytes that have moved, `<path>` resolves to a
// truncated string, and hover underlines the wrong cells.
//
// It is what makes a document that is BOTH a listing and a text field possible at all — a file
// browser you rename in — because the alternative is the producer republishing its whole
// descriptor per keystroke, and it cannot do that for an edit the kernel applied itself.
//
// The rule at a boundary is the one an editor already has: text typed at either edge of a link
// belongs to the link, so a name grows as you extend it. Text that swallows a link whole takes
// it with it — a span whose ends meet, or whose ends land on two different lines, is dropped
// rather than left pointing at something it no longer covers.

// Folds every splice this reader has not seen into the slot's descriptor. Cheap and total: with
// nothing to fold it is a compare, and every reader of a descriptor comes through here, so no
// caller can see a span the text has moved out from under.
@(private)
fields_follow :: proc(slot: ^Slot) {
    if slot.doc == nil || slot.desc == nil {
        return
    }
    changes, lost := txt.doc_changes_since(slot.doc, .Fields)
    if len(changes) == 0 && !lost {
        return
    }
    defer txt.doc_changes_ack(slot.doc, .Fields)
    if len(slot.desc.fields) == 0 {
        return
    }
    // The log no longer reaches back far enough to say where the spans went. A link that MIGHT
    // point at the wrong thing is worse than none, so they go and the owner republishes when it
    // is told the generation moved (§7).
    if lost {
        fields_replace(slot, nil)
        return
    }
    kept := make([dynamic]desc.Field, 0, len(slot.desc.fields), context.temp_allocator)
    for f in slot.desc.fields {
        moved := f
        alive := true
        for ch in changes {
            moved, alive = field_shift(moved, ch)
            if !alive {
                break
            }
        }
        if alive {
            append(&kept, moved)
        }
    }
    if len(kept) != len(slot.desc.fields) || !slice.equal(kept[:], slot.desc.fields) {
        fields_replace(slot, kept[:])
    }
}

// The descriptor with other fields on it. Immutable and shared, so this is a new one: whoever
// holds the old pointer keeps reading the spans that were true when they took it (§6).
@(private = "file")
fields_replace :: proc(slot: ^Slot, fields: []desc.Field) {
    next := slot.desc^
    next.fields = fields
    d := desc.new_from(next)
    desc.release(slot.desc)
    slot.desc = d
}

// One field through one splice. False means the field did not survive it.
@(private = "file")
field_shift :: proc(f: desc.Field, ch: txt.Doc_Change) -> (desc.Field, bool) {
    lo := txt.point_shift({f.line, f.lo}, ch, low = true)
    hi := txt.point_shift({f.line, f.hi}, ch, low = false)
    if lo.line != hi.line || lo.col >= hi.col {
        return f, false
    }
    out := f
    out.line, out.lo, out.hi = lo.line, lo.col, hi.col
    return out, true
}

package txt

import "core:slice"
import "../rc"

// An immutable read of a document at one generation: the piece list and the line index as they
// stood, over the arena they point into. This is the read path of §6 — a holder reads text,
// line starts and spans directly out of it, with no call into the kernel and no lock.
//
// Cheap to take: the two arrays are bounded by the compaction thresholds and the bytes are
// shared, so this is a small copy plus a refcount bump, not a copy of the document.
//
// Cheap to hold: the arena never rewrites a byte or a line start it has written, and never
// moves the arrays holding them — an append that outgrows a buffer retires it rather than
// freeing it (piecetable.odin). So `blocks` and `starts` below are captured by value, as the
// prefixes they were at this generation, and nothing the main thread does afterwards reaches
// them.
//
// Every txt read proc takes a ^Text, and Snapshot embeds one, so reading a snapshot goes
// through exactly the code that reads the live table.
Snapshot :: struct {
    using text: Text,
    rc:         int, // atomic; a worker thread may hold the last reference
    gen:        u64, // the document generation this froze
}

// The caller owns one reference and releases it. `gen` is what a later write rebases against:
// a submit carrying it is applied only if the document has not moved since (see store).
snapshot_take :: proc(pt: ^Piece_Table, gen: u64) -> ^Snapshot {
    s := new(Snapshot)
    s.rc = 1
    s.gen = gen
    s.arena = pt.arena
    arena_retain(s.arena)
    // Slice headers by value: the writer's own grow past the end, ours keeps naming the prefix.
    s.blocks = pt.blocks
    s.starts = pt.starts
    s.pieces = slice.clone_to_dynamic(pt.pieces[:])
    s.segs = slice.clone_to_dynamic(pt.segs[:])
    s.size = pt.size
    s.lines = pt.lines
    return s
}

snapshot_retain :: proc(s: ^Snapshot) {
    rc.retain(&s.rc)
}

// The arena outlives this whenever another snapshot or the live table still holds it.
snapshot_release :: proc(s: ^Snapshot) {
    if !rc.release(&s.rc) {
        return
    }
    arena_release(s.arena)
    delete(s.pieces)
    delete(s.segs)
    free(s)
}

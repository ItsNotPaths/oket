package tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "../txt"

// The gate for build order stage 2: a snapshot survives 10k edits, leaks nothing, and reads
// with no lock. The edits below are scattered on purpose — a typing run coalesces into one
// piece and would exercise none of the piece splitting, index re-delta or arena renewal that
// a snapshot has to survive.

// Walks the snapshot's spans rather than calling text_read, so this allocates nothing. The
// reader thread below needs that: the claim is that a snapshot reads with no lock, and a test
// that took the allocator's would not be testing it.
@(private = "file")
snap_is :: proc(s: ^txt.Snapshot, want: string) -> bool {
    if s.size != len(want) {
        return false
    }
    at := 0
    for at < s.size {
        span := txt.text_span(s, at)
        if len(span) == 0 || string(span) != want[at:at + len(span)] {
            return false
        }
        at += len(span)
    }
    return true
}

// Reads the line index rather than the bytes, and allocates nothing either. Worth its own
// check: the starts live in a different arena buffer from the blocks, and they are the ones
// that grow hardest under the stress below.
@(private = "file")
snap_lines_are :: proc(s: ^txt.Snapshot, want: string) -> bool {
    if txt.text_line_count(s) != strings.count(want, "\n") + 1 {
        return false
    }
    line, at := 0, 0
    for {
        if txt.text_line_start(s, line) != at {
            return false
        }
        nl := strings.index_byte(want[at:], '\n')
        if nl < 0 {
            return true
        }
        at, line = at + nl + 1, line + 1
    }
}

// A deterministic scatter over the document: an insert and a delete per round, at offsets that
// walk the whole file rather than staying at one caret. Every third insert carries a newline,
// so the line index churns as hard as the text does.
@(private = "file")
stress :: proc(d: ^txt.Doc, mirror: ^strings.Builder, rounds: int) {
    for i in 0 ..< rounds {
        text := fmt.tprintf("<%d>%s", i % 100, i % 3 == 0 ? "\n" : "")
        at := (i * 7919) % (strings.builder_len(mirror^) + 1)
        txt.doc_apply(d, {txt.Edit{lo = at, hi = at, text = text}})
        inject_at_elems(&mirror.buf, at, ..transmute([]u8)text)

        if strings.builder_len(mirror^) > 64 {
            cut := (i * 104729) % (strings.builder_len(mirror^) - 3)
            txt.doc_apply(d, {txt.Edit{lo = cut, hi = cut + 3}})
            remove_range(&mirror.buf, cut, cut + 3)
        }
    }
}

// The stage gate itself. Split out of the test so every allocation it makes is freed before
// the caller reads the tracker: a defer would still be pending at the point of the check.
@(private = "file")
survive_10k :: proc(t: ^testing.T) {
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "alpha\nbeta\ngamma\ndelta\n")

    base := txt.doc_string(&d)
    defer delete(base)
    snap := txt.doc_snapshot(&d)
    defer txt.snapshot_release(snap)
    gen := snap.gen
    lines := txt.text_line_count(snap)

    mirror := strings.builder_make()
    defer strings.builder_destroy(&mirror)
    strings.write_string(&mirror, base)
    stress(&d, &mirror, 10_000)

    testing.expect(t, snap_is(snap, base), "10k edits moved the bytes under a live snapshot")
    testing.expect_value(t, txt.text_line_count(snap), lines)
    testing.expect_value(t, snap.gen, gen)
    testing.expect(t, d.gen > gen, "the generation must have moved")

    // And the document itself is still right, so the snapshot did not cost correctness.
    live := txt.doc_string(&d, context.temp_allocator)
    testing.expect_value(t, live, strings.to_string(mirror))
}

// The runner's own tracker only warns on a leak, and "no leak" is half of what stage 2 gates
// on, so the stress runs under a tracker of its own and fails on one.
@(test)
snapshot_survives_10k_edits :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)

    {
        context.allocator = mem.tracking_allocator(&track)
        survive_10k(t)
    }

    for _, leak in track.allocation_map {
        testing.expectf(t, false, "leaked %d bytes, allocated at %v", leak.size, leak.location)
    }
    testing.expect_value(t, len(track.bad_free_array), 0)
}

// Several generations held at once, each still reading its own. This is what a worker taking a
// snapshot per job and finishing out of order looks like.
@(test)
snapshot_holds_many_generations :: proc(t: ^testing.T) {
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "one\ntwo\nthree\n")

    mirror := strings.builder_make()
    defer strings.builder_destroy(&mirror)
    strings.write_string(&mirror, txt.doc_string(&d, context.temp_allocator))

    snaps: [10]^txt.Snapshot
    wants: [10]string
    for i in 0 ..< 10 {
        snaps[i] = txt.doc_snapshot(&d)
        wants[i] = strings.clone(strings.to_string(mirror))
        stress(&d, &mirror, 500)
    }
    defer for i in 0 ..< 10 {
        txt.snapshot_release(snaps[i])
        delete(wants[i])
    }

    for i in 0 ..< 10 {
        testing.expectf(t, snap_is(snaps[i], wants[i]), "snapshot %d lost its generation", i)
        testing.expectf(t, snaps[i].gen < d.gen, "snapshot %d should be behind the doc", i)
    }
}

// Compaction is the one operation that throws away every block the pieces point at, so it is
// the case a shared arena has to get right.
@(test)
snapshot_survives_compaction :: proc(t: ^testing.T) {
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "alpha\nbeta\ngamma\n")

    mirror := strings.builder_make()
    defer strings.builder_destroy(&mirror)
    strings.write_string(&mirror, txt.doc_string(&d, context.temp_allocator))
    stress(&d, &mirror, 3000)

    want := strings.clone(strings.to_string(mirror))
    defer delete(want)
    snap := txt.doc_snapshot(&d)
    defer txt.snapshot_release(snap)

    txt.pt_compact(&d.pt)
    testing.expect(t, snap_is(snap, want), "compaction pulled the blocks out from under a snapshot")
    live := string(txt.text_read(&d.pt, 0, d.pt.size, context.temp_allocator))
    testing.expect_value(t, live, want)

    // A second round with the snapshot still held: the fresh arena has to behave like any other.
    stress(&d, &mirror, 1000)
    testing.expect(t, snap_is(snap, want), "editing after compaction reached the old arena")
}

// A snapshot outliving its document. A worker holding one while the user closes the buffer is
// the ordinary case, not the exotic one.
@(test)
snapshot_outlives_its_doc :: proc(t: ^testing.T) {
    d := new(txt.Doc)
    txt.doc_init(d)
    txt.doc_set_text(d, "kept\nafter\nclose\n")
    want := txt.doc_string(d)
    defer delete(want)

    snap := txt.doc_snapshot(d)
    defer txt.snapshot_release(snap)
    txt.doc_destroy(d)
    free(d)

    testing.expect(t, snap_is(snap, want), "the document's death took the snapshot's bytes")
    testing.expect_value(t, txt.text_line_count(snap), 3)
}

// Blocks bigger than PT_CHUNK each get one of their own, so this grows the block list far
// faster than typing would — the other arena array a reader indexes into.
@(private = "file")
grow_blocks :: proc(d: ^txt.Doc, mirror: ^strings.Builder, blocks: int) {
    big := strings.repeat("z", 70 * 1024, context.temp_allocator)
    for _ in 0 ..< blocks {
        txt.doc_apply(d, {txt.Edit{lo = 0, hi = 0, text = big}})
        inject_at_elems(&mirror.buf, 0, ..transmute([]u8)big)
    }
}

@(private = "file")
Reader :: struct {
    snap:  ^txt.Snapshot,
    want:  string,
    reads: int,
    bad:   int,
    stop:  bool,
}

@(private = "file")
read_until_stopped :: proc(r: ^Reader) {
    for !sync.atomic_load(&r.stop) {
        if !snap_is(r.snap, r.want) || !snap_lines_are(r.snap, r.want) {
            r.bad += 1
        }
        r.reads += 1
    }
}

// The "no lock on the read path" half of the gate. There is no lock to assert on, so the test
// is behavioural: a second thread reads a snapshot end to end, bytes and line index both, over
// and over, while the main thread edits the document it came from. Every read must be whole
// and correct.
//
// The edits are chosen to make both arena arrays outgrow their buffers several times over,
// which is the case that would catch a reader out if a full buffer were freed rather than
// retired.
@(test)
snapshot_reads_off_thread :: proc(t: ^testing.T) {
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "alpha\nbeta\ngamma\ndelta\nepsilon\n")

    want := txt.doc_string(&d)
    defer delete(want)
    r := Reader {
        snap = txt.doc_snapshot(&d),
        want = want,
    }
    defer txt.snapshot_release(r.snap)

    worker := thread.create_and_start_with_poly_data(&r, read_until_stopped)
    defer thread.destroy(worker)

    mirror := strings.builder_make()
    defer strings.builder_destroy(&mirror)
    strings.write_string(&mirror, want)
    stress(&d, &mirror, 10_000)
    grow_blocks(&d, &mirror, 40)

    sync.atomic_store(&r.stop, true)
    thread.join(worker)

    testing.expect_value(t, r.bad, 0)
    testing.expect(t, r.reads > 0, "the reader thread never got a read in")

    // The run only proves anything if the arena did outgrow its buffers while the reader held
    // slices into them. More than one buffer in either list is exactly that having happened.
    testing.expect(t, len(d.pt.arena.starts) > 1, "the line pool never outgrew its first buffer")
    testing.expect(t, len(d.pt.arena.spines) > 1, "the block list never outgrew its first buffer")
}


// §10's storage invariant, and the claim that a snapshot answers it as well as a live table
// does: both are a Text, and the last piece's end is the size in either.
@(test)
text_check_reads_a_snapshot_and_a_live_table_alike :: proc(t: ^testing.T) {
    d: txt.Doc
    txt.doc_init(&d)
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "alpha\nbeta\ngamma")
    for at in ([?]int{0, 7, 3, 11}) {
        txt.doc_apply(&d, {txt.Edit{lo = at, hi = at, text = "<>"}})
    }
    snap := txt.doc_snapshot(&d)
    defer txt.snapshot_release(snap)
    testing.expect(t, len(d.pt.pieces) > 1, "the edits did not splinter the table")
    testing.expect(t, txt.text_check(&d.pt), "a healthy table failed")
    testing.expect(t, txt.text_check(snap), "a healthy snapshot failed")

    // A splice that lost its way: the running total no longer lands on the size, which is what
    // a binary search would otherwise walk off the end of.
    d.pt.pieces[len(d.pt.pieces) - 1].len -= 1
    testing.expect(t, !txt.text_check(&d.pt), "a broken running total passed")
    testing.expect(t, txt.text_check(snap), "the snapshot's own copy moved with it")
    d.pt.pieces[len(d.pt.pieces) - 1].len += 1
}

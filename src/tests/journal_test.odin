package tests

import "core:encoding/endian"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../edit"
import "../txt"

// The step-9 gate, third claim: unsaved work survives a crash.
//
// The point of §10's design is that recovery reads only bytes already on the platter. Nothing
// here serializes a Buffer, so nothing here depends on the piece table being intact — which is
// the state a crash is least entitled to trust.

@(test)
journal_recovers_unsaved_edits :: proc(t: ^testing.T) {
    dir, doc, made := journal_dirs()
    if !testing.expect(t, made, "could not make a temp directory") {
        return
    }
    defer cleanup_dir(dir)
    defer delete(doc)

    if !testing.expect_value(t, os.write_entire_file(doc, "one\ntwo\n"), nil) {
        return
    }

    b: edit.Buffer
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_load(&b, doc), "the buffer did not load")
    testing.expect(t, edit.journal_begin(&b, dir), "the journal did not open")

    // Edits, and never a save: this is the work a crash would otherwise take.
    edit.buffer_insert_rune(&b, 'X')
    edit.buffer_insert_rune(&b, 'Y')
    want := txt.doc_string(&b.doc, context.temp_allocator)

    // The process dies here. Nothing flushes, nothing serializes; the journal is whatever
    // write() already handed the kernel.
    journal, _ := filepath.join({dir, edit.journal_name(doc)}, context.temp_allocator)
    testing.expect(t, os.exists(journal), "no journal file was written")

    r, ok := edit.journal_recover(journal)
    if !testing.expect(t, ok, "the journal did not replay") {
        return
    }
    defer edit.recovered_destroy(&r)
    testing.expect_value(t, r.path, doc)
    testing.expect_value(t, r.content, want)
    testing.expect_value(t, r.edits, 2)

    // Only now, so the assertions above ran against a journal nobody closed.
    edit.journal_end(&b)
    edit.buffer_destroy(&b)
}

// A save is the end of the journal's job: the file now says what the journal said, and a
// leftover would offer to recover work that is already on disk.
@(test)
journal_clears_on_save :: proc(t: ^testing.T) {
    dir, doc, made := journal_dirs()
    if !testing.expect(t, made, "could not make a temp directory") {
        return
    }
    defer cleanup_dir(dir)
    defer delete(doc)
    testing.expect_value(t, os.write_entire_file(doc, "one\n"), nil)

    b: edit.Buffer
    edit.buffer_init(&b)
    defer edit.buffer_destroy(&b)
    testing.expect(t, edit.buffer_load(&b, doc), "the buffer did not load")
    testing.expect(t, edit.journal_begin(&b, dir), "the journal did not open")
    edit.buffer_insert_rune(&b, 'Z')

    journal, _ := filepath.join({dir, edit.journal_name(doc)}, context.temp_allocator)
    testing.expect(t, os.exists(journal), "no journal before the save")

    // buffer_save marks saved, and journaling restarts from the new clean base. With no
    // journal_dir set for tests, that leaves nothing behind.
    testing.expect_value(t, edit.buffer_save(&b), edit.Save_Result.Ok)
    testing.expect(t, !os.exists(journal), "the journal outlived the save it recorded")
}

// A torn tail is the normal way a journal ends: the process died mid-write. Everything before
// the torn record still has to come back.
@(test)
journal_survives_a_torn_tail :: proc(t: ^testing.T) {
    dir, doc, made := journal_dirs()
    if !testing.expect(t, made, "could not make a temp directory") {
        return
    }
    defer cleanup_dir(dir)
    defer delete(doc)
    testing.expect_value(t, os.write_entire_file(doc, "abc"), nil)

    b: edit.Buffer
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_load(&b, doc), "the buffer did not load")
    testing.expect(t, edit.journal_begin(&b, dir), "the journal did not open")
    edit.buffer_insert_rune(&b, 'Q')
    edit.buffer_insert_rune(&b, 'R')
    edit.journal_detach(&b) // what a crash leaves: fd gone, bytes on disk
    edit.buffer_destroy(&b)

    journal, _ := filepath.join({dir, edit.journal_name(doc)}, context.temp_allocator)
    whole, err := os.read_entire_file(journal, context.temp_allocator)
    if !testing.expect_value(t, err, nil) {
        return
    }
    full, full_ok := edit.journal_recover(journal)
    if !testing.expect(t, full_ok, "the intact journal did not replay") {
        return
    }
    defer edit.recovered_destroy(&full)

    // Chop a byte off: the last record is now short, and only it should be lost.
    testing.expect_value(t, os.write_entire_file(journal, whole[:len(whole) - 1]), nil)
    torn, torn_ok := edit.journal_recover(journal)
    if !testing.expect(t, torn_ok, "a torn journal was refused outright") {
        return
    }
    defer edit.recovered_destroy(&torn)
    testing.expect_value(t, torn.edits, full.edits - 1)
    testing.expect(t, len(torn.content) > 0, "a torn journal recovered nothing at all")
}

// Garbage is refused rather than replayed into a wrong document.
@(test)
journal_refuses_a_foreign_file :: proc(t: ^testing.T) {
    dir, doc, made := journal_dirs()
    if !testing.expect(t, made, "could not make a temp directory") {
        return
    }
    defer cleanup_dir(dir)
    defer delete(doc)
    junk, _ := filepath.join({dir, "junk.okjrnl"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(junk, "not a journal at all"), nil)
    _, ok := edit.journal_recover(junk)
    testing.expect(t, !ok, "a non-journal file replayed")
}

// The replay parses lengths a crash (or an attacker) wrote: a record claiming more bytes
// than exist must end the replay, never index past the file or the document.
@(test)
journal_refuses_hostile_lengths :: proc(t: ^testing.T) {
    dir, doc, made := journal_dirs()
    if !testing.expect(t, made, "could not make a temp directory") {
        return
    }
    defer cleanup_dir(dir)
    defer delete(doc)

    HUGE :: u64(0xFFFF_FFFF_FFFF_FFFF)
    body := [?]struct {
        pos, old_len, new_len: u64,
    }{{0, 0, HUGE}, {HUGE, 0, 0}, {0, HUGE, 0}}
    for rec, i in body {
        b := strings.builder_make(context.temp_allocator)
        strings.write_string(&b, "okjrnl\x00\x00")
        raw_u32(&b, 1) // version
        raw_u64(&b, 0) // path ""
        raw_u64(&b, 2)
        strings.write_string(&b, "ab") // base
        raw_u64(&b, rec.pos)
        raw_u64(&b, rec.old_len)
        raw_u64(&b, rec.new_len)
        strings.write_string(&b, "xyz") // fewer bytes than any hostile length claims

        file, _ := filepath.join({dir, "hostile.okjrnl"}, context.temp_allocator)
        werr := os.write_entire_file(file, transmute([]u8)strings.to_string(b))
        if !testing.expect_value(t, werr, nil) {
            return
        }
        r, ok := edit.journal_recover(file)
        if !testing.expectf(t, ok, "record %d refused the whole journal, base and all", i) {
            continue
        }
        defer edit.recovered_destroy(&r)
        testing.expect_value(t, r.content, "ab") // the base survives, the lie does not
        testing.expect_value(t, r.edits, 0)
    }
}

@(private = "file")
raw_u32 :: proc(b: ^strings.Builder, v: u32) {
    buf: [4]u8
    endian.put_u32(buf[:], .Little, v)
    strings.write_bytes(b, buf[:])
}

@(private = "file")
raw_u64 :: proc(b: ^strings.Builder, v: u64) {
    buf: [8]u8
    endian.put_u64(buf[:], .Little, v)
    strings.write_bytes(b, buf[:])
}

// A path is not a filename, and two documents must not share one journal.
@(test)
journal_names_are_distinct :: proc(t: ^testing.T) {
    a := edit.journal_name("/home/x/a.txt", context.temp_allocator)
    b := edit.journal_name("/home/y/a.txt", context.temp_allocator)
    testing.expect(t, a != b, "two paths produced one journal name")
    testing.expect(t, !strings.contains(a, "/"), "a journal name kept a separator")
}

@(private = "file")
journal_dirs :: proc() -> (dir: string, doc: string, ok: bool) {
    d, err := os.make_directory_temp("", "oket-journal-*", context.allocator)
    if err != nil {
        return "", "", false
    }
    joined, _ := filepath.join({d, "doc.txt"}, context.allocator)
    return d, joined, true
}

@(private = "file")
cleanup_dir :: proc(dir: string) {
    f, err := os.open(dir)
    if err == nil {
        it := os.read_directory_iterator_create(f)
        for info in os.read_directory_iterator(&it) {
            os.remove(info.fullpath)
        }
        os.read_directory_iterator_destroy(&it)
        os.close(f)
    }
    os.remove(dir)
    delete(dir)
}

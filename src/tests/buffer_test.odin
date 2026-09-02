package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../edit"
import "../txt"

// The gate for build order step 3: open, edit, save, undo, reload on external change.

@(private = "file")
mkbuf :: proc(text: string) -> edit.Buffer {
    b: edit.Buffer
    edit.buffer_init(&b)
    edit.buffer_set_text(&b, text)
    return b
}

@(private = "file")
lstr :: proc(b: ^edit.Buffer, i: int) -> string {
    return string(txt.doc_line(&b.doc, i, context.temp_allocator))
}

@(test)
buffer_newline_splits :: proc(t: ^testing.T) {
    b := mkbuf("hello")
    defer edit.buffer_destroy(&b)
    edit.buffer_motion(&b, .Right)
    edit.buffer_motion(&b, .Right) // column 2
    edit.buffer_newline(&b)
    testing.expect_value(t, txt.doc_line_count(&b.doc), 2)
    testing.expect_value(t, lstr(&b, 0), "he")
    testing.expect_value(t, lstr(&b, 1), "llo")
    testing.expect(t, b.dirty)
}

@(test)
buffer_backspace_joins :: proc(t: ^testing.T) {
    b := mkbuf("ab\ncd")
    defer edit.buffer_destroy(&b)
    edit.buffer_motion(&b, .Down) // line 1, column 0
    edit.buffer_backspace(&b)
    testing.expect_value(t, txt.doc_line_count(&b.doc), 1)
    testing.expect_value(t, lstr(&b, 0), "abcd")
    testing.expect_value(t, b.cursors[0].head.col, 2)
}

@(test)
buffer_vertical_goal_column :: proc(t: ^testing.T) {
    b := mkbuf("hello\nhi\nworld")
    defer edit.buffer_destroy(&b)
    edit.buffer_motion(&b, .End) // column 5 on "hello"; goal = 5
    edit.buffer_motion(&b, .Down) // "hi" is short -> clamps to 2
    testing.expect_value(t, b.cursors[0].head.col, 2)
    edit.buffer_motion(&b, .Down) // "world" -> goal 5 restored
    testing.expect_value(t, b.cursors[0].head.col, 5)
}

@(test)
buffer_undo_redo_round_trip :: proc(t: ^testing.T) {
    b := mkbuf("one")
    defer edit.buffer_destroy(&b)
    edit.buffer_motion(&b, .End)
    edit.buffer_insert_text(&b, " two")
    testing.expect_value(t, lstr(&b, 0), "one two")

    edit.buffer_undo(&b)
    testing.expect_value(t, lstr(&b, 0), "one")
    edit.buffer_redo(&b)
    testing.expect_value(t, lstr(&b, 0), "one two")
}

// load -> save round-trips the file's final newline, or its absence, byte for byte.
@(test)
buffer_save_preserves_final_newline :: proc(t: ^testing.T) {
    for src in ([]string{"a\nb\n", "a\nb", "", "\n"}) {
        path := "oket_nl_roundtrip.tmp"
        testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
        defer os.remove(path)

        b: edit.Buffer
        defer edit.buffer_destroy(&b)
        edit.buffer_init(&b)
        testing.expect(t, edit.buffer_load(&b, path))
        testing.expect_value(t, edit.buffer_save(&b), edit.Save_Result.Ok)

        out, err := os.read_entire_file_from_path(path, context.temp_allocator)
        testing.expect(t, err == nil)
        testing.expect_value(t, string(out), src)
    }
}

// A CRLF file is edited as if it were LF and written back the way it came.
@(test)
buffer_crlf_round_trip :: proc(t: ^testing.T) {
    path := "oket_crlf.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("a\r\nb\r\n")) == nil)
    defer os.remove(path)

    b: edit.Buffer
    defer edit.buffer_destroy(&b)
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_load(&b, path))
    testing.expect(t, b.crlf)
    testing.expect_value(t, lstr(&b, 1), "b") // no '\r' in the document itself

    testing.expect_value(t, edit.buffer_save(&b), edit.Save_Result.Ok)
    out, err := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect_value(t, string(out), "a\r\nb\r\n")

    testing.expect(t, !edit.crlf_file("a\nb\r\n"))
    testing.expect(t, edit.crlf_file("a\r\nb\n"))
}

// The save writes a sibling temp file and renames it over the target: the file keeps its
// permissions, no temp file is left behind, and a read-only file still refuses.
@(test)
buffer_save_is_atomic :: proc(t: ^testing.T) {
    dir := "oket_atomic_dir"
    testing.expect(t, os.make_directory(dir) == nil)
    defer os.remove_all(dir)
    path := fmt.tprintf("%s/oket_atomic.tmp", dir)
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("one\n")) == nil)
    mode := os.Permissions{.Read_User, .Write_User, .Execute_User}
    testing.expect(t, os.chmod(path, mode) == nil)

    b: edit.Buffer
    defer edit.buffer_destroy(&b)
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_load(&b, path))
    edit.buffer_insert_rune(&b, 'X')
    testing.expect_value(t, edit.buffer_save(&b), edit.Save_Result.Ok)

    fi, err := os.stat(path, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect(t, fi.mode == mode) // the target's own bits, not a fresh file's defaults

    left, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
    testing.expect(t, derr == nil)
    testing.expect_value(t, len(left), 1) // the file alone: the temp one is gone

    if os.get_euid() != 0 { // root is refused nothing
        edit.buffer_insert_rune(&b, 'Y')
        testing.expect(t, os.chmod(path, {.Read_User}) == nil)
        testing.expect_value(t, edit.buffer_save(&b), edit.Save_Result.Denied)
        testing.expect(t, b.dirty, "a refused save must leave the buffer dirty")
        testing.expect(t, os.chmod(path, mode) == nil)
    }
}

// A symlinked file is saved THROUGH the link, so the link is still a link afterwards.
@(test)
buffer_save_follows_symlink :: proc(t: ^testing.T) {
    target := "oket_symlink_target.tmp"
    link := "oket_symlink.tmp"
    testing.expect(t, os.write_entire_file(target, transmute([]u8)string("one\n")) == nil)
    defer os.remove(target)
    os.remove(link)
    testing.expect(t, os.symlink(target, link) == nil)
    defer os.remove(link)

    b: edit.Buffer
    defer edit.buffer_destroy(&b)
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_load(&b, link))
    edit.buffer_insert_rune(&b, 'X')
    testing.expect_value(t, edit.buffer_save(&b), edit.Save_Result.Ok)

    fi, err := os.lstat(link, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect(t, fi.type == .Symlink, "the save replaced the link with a regular file")
    out, rerr := os.read_entire_file_from_path(target, context.temp_allocator)
    testing.expect(t, rerr == nil)
    testing.expect_value(t, string(out), "Xone\n")
}

// External edits flow into a CLEAN buffer, so a later save cannot clobber them; a DIRTY buffer
// keeps the user's work and raises the conflict. The forced-stale stamp dodges filesystem
// mtime granularity.
@(test)
buffer_reload_if_changed_and_conflict :: proc(t: ^testing.T) {
    path := "oket_reload.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("one\ntwo\n")) == nil)
    defer os.remove(path)

    b: edit.Buffer
    defer edit.buffer_destroy(&b)
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_load(&b, path))

    // Unchanged on disk: a no-op, since the stamp matches.
    testing.expect(t, !edit.buffer_reload_if_changed(&b, true))

    // An external rewrite of a clean buffer reloads, and the caret clamps into range.
    edit.buffer_motion(&b, .Down)
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("ALPHA\n")) == nil)
    b.disk_mtime = {}
    testing.expect(t, edit.buffer_reload_if_changed(&b, true))
    testing.expect_value(t, lstr(&b, 0), "ALPHA")
    testing.expect_value(t, b.cursors[0].head.line, 0) // clamped from line 1
    testing.expect_value(t, b.path, path) // the path survived the reload

    // A dirty buffer in prompt mode is a real conflict: the change is not pulled in, and the
    // stamp is left unadopted so it keeps asserting.
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("BETA\n")) == nil)
    b.dirty = true
    b.disk_mtime = {}
    testing.expect(t, !edit.buffer_reload_if_changed(&b, true))
    testing.expect(t, b.conflict)
    testing.expect_value(t, lstr(&b, 0), "ALPHA") // untouched

    // "Keep mine" resolves it and caches against the current disk version.
    edit.buffer_conflict_resolve(&b, false)
    testing.expect(t, !b.conflict)
    testing.expect(t, !edit.buffer_reload_if_changed(&b, true)) // stamp adopted -> quiet

    // A fresh on-disk change re-raises it, and "reload" takes the disk version.
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("GAMMA\n")) == nil)
    b.disk_mtime = {}
    testing.expect(t, !edit.buffer_reload_if_changed(&b, true))
    testing.expect(t, b.conflict)
    edit.buffer_conflict_resolve(&b, true)
    testing.expect(t, !b.conflict)
    testing.expect(t, !b.dirty)
    testing.expect_value(t, lstr(&b, 0), "GAMMA")
}

// A discard that cannot reload must not claim the buffer is clean: the edits in hand are the
// only copy of themselves.
@(test)
buffer_failed_discard_keeps_the_edits :: proc(t: ^testing.T) {
    path := "oket_discard_gone.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("disk\n")) == nil)

    b: edit.Buffer
    defer edit.buffer_destroy(&b)
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_load(&b, path))
    edit.buffer_insert_text(&b, "MINE")

    os.remove(path) // the file goes while the edits are unsaved
    testing.expect(t, !edit.buffer_discard(&b))
    testing.expect(t, b.dirty, "a failed discard must leave the buffer dirty")
    testing.expect(t, strings.contains(txt.doc_string(&b.doc, context.temp_allocator), "MINE"))
}

// A missing file opens empty with the path set, and the first save creates it.
@(test)
buffer_open_missing_file :: proc(t: ^testing.T) {
    path := "oket_fresh.tmp"
    os.remove(path)

    b: edit.Buffer
    defer edit.buffer_destroy(&b)
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_open(&b, path))
    testing.expect_value(t, b.path, path)
    testing.expect_value(t, txt.doc_line_count(&b.doc), 1)

    edit.buffer_insert_text(&b, "born")
    testing.expect_value(t, edit.buffer_save(&b), edit.Save_Result.Ok)
    defer os.remove(path)
    out, err := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect_value(t, string(out), "born\n")
}

// pt_compact is the only thing that flattens a splintered table, and a save is where it runs.
@(test)
buffer_save_compacts_a_splintered_table :: proc(t: ^testing.T) {
    path := "oket_compact.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("hello world\n")) == nil)
    defer os.remove(path)

    b: edit.Buffer
    defer edit.buffer_destroy(&b)
    edit.buffer_init(&b)
    testing.expect(t, edit.buffer_load(&b, path))

    for i in 0 ..< txt.PT_COMPACT_PIECES {
        txt.doc_reset_cursor(&b.doc, {0, i % 2 == 0 ? 0 : 3})
        txt.doc_insert_rune(&b.doc, 'z')
    }
    testing.expect(t, txt.pt_should_compact(&b.doc.pt))
    want := txt.doc_string(&b.doc, context.temp_allocator)

    testing.expect_value(t, edit.buffer_save(&b), edit.Save_Result.Ok)
    testing.expect(t, !txt.pt_should_compact(&b.doc.pt), "a save must flatten the table")
    testing.expect_value(t, txt.doc_string(&b.doc, context.temp_allocator), want)
}

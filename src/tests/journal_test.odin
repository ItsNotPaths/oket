package tests

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../desc"
import "../store"
import app "../oket"

// Stage 13's gate: kill -9 mid-edit, restart, work intact.
//
// The half a test cannot do to itself is the kill. `journal_detach` is that half — the fd goes
// and the bytes stay, which is exactly what a process death leaves — and everything after it
// runs in a SECOND App over the same home, so what is asserted is a restart and not a rollback.
//
// Nothing here serializes a piece table, which is the point of §10's design: recovery reads
// bytes that were already on the platter, and the piece table is the state a crash is least
// entitled to trust.

// An editor, a file open in it, and the journal running. Answers the home directory as well,
// because the restart is another App over the same one.
@(private = "file")
crash_app :: proc(t: ^testing.T, name, text: string) ->
                  (a: app.App, path, home: string, ok: bool) {
    a = plug_app(t, name, "plugins/edit") or_return
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "edit")), a.message) {
        close_plug_app(&a)
        return {}, "", "", false
    }
    // A space in the name on purpose: the page's `enter` fills a hole, and the quote pair a
    // hole adds has to come off again at the builtin.
    path, _ = filepath.join({a.home, "my note.txt"}, context.allocator)
    if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
        testing.expectf(t, false, "cannot write %s: %v", path, err)
        close_plug_app(&a)
        return {}, "", "", false
    }
    app.cl_exec(&a, fmt.tprintf(":open %q", path))
    if !testing.expect(t, app.ring_focused(&a.ring) != nil, a.message) {
        close_plug_app(&a)
        return {}, "", "", false
    }
    app.surface_draw(&a)
    app.docs_settle(&a) // the frame that starts the journal, based on what the file said
    return a, path, strings.clone(a.home), true
}

// The restart. A fresh App over a home that already has a journal in it, with the plugins that
// home holds, which is every start after a crash.
@(private = "file")
restart :: proc(home: string) -> (a: app.App, ok: bool) {
    a = bare_app() or_return
    a.home = strings.clone(home)
    app.plug_init(&a)
    app.plug_autoload(&a)
    return a, true
}

// The gate, end to end.
@(test)
work_survives_a_crash_and_a_restart :: proc(t: ^testing.T) {
    a, path, home, ok := crash_app(t, "oket-journal-gate", "one\ntwo\n")
    if !ok {
        return
    }
    defer delete(home)
    defer delete(path)

    id := app.ring_focused(&a.ring).doc
    app.handle_chord(&a, chord("END"))
    for r in "XY" {
        app.text_input(&a, r)
    }
    want := doc_text(&a, id)
    testing.expect_value(t, want, "oneXY\ntwo\n")

    // The process dies here: nothing is flushed and nothing is serialized.
    testing.expect(t, app.journal_detach(&a, id), "the document was not being journaled")
    close_plug_app(&a)

    b, made := restart(home)
    if !testing.expect(t, made, "the restart made no App") {
        return
    }
    defer close_plug_app(&b)

    work := app.recover_scan(&b)
    if !testing.expect_value(t, len(work), 1) {
        return
    }
    testing.expect_value(t, work[0].path, path)
    testing.expect(t, work[0].edits > 0, "the journal recovered no edits at all")

    // Through the home page, which is what a start after a crash opens: point on the row, and
    // `enter`. No dialog, no mode, no key job — one bind over one field (§13).
    page := app.home_open(&b)
    app.ring_add(&b, page)
    app.surface_draw(&b)
    for _ in 0 ..< home_row(&b, page) {
        app.handle_chord(&b, chord("DOWN"))
    }
    app.handle_chord(&b, chord("RTRN"))
    testing.expect_value(t, focused_text(&b), want)
    // And the offer is gone: the work is in a document now, and a second start must not offer
    // it again over a file that still says something else.
    testing.expect_value(t, len(app.recover_scan(&b)), 0)
}

// Which line of the page carries the first row of recovered work.
@(private = "file")
home_row :: proc(a: ^app.App, page: store.Id) -> int {
    d := store.store_descriptor(&a.docs, page)
    defer desc.release(d)
    for f in d.fields {
        if f.name == "path" {
            return f.line
        }
    }
    return 0
}

// A clean exit is not a crash. The journal goes with the App, or every start would open on a
// page offering back work that nothing is missing.
@(test)
a_clean_exit_leaves_no_journal :: proc(t: ^testing.T) {
    a, path, home, ok := crash_app(t, "oket-journal-clean", "one\n")
    if !ok {
        return
    }
    defer delete(home)
    defer delete(path)
    journal := strings.clone(app.journal_path(&a, path), context.allocator)
    defer delete(journal)

    app.text_input(&a, 'Z')
    testing.expect(t, os.exists(journal), "no journal while a document was being edited")
    close_plug_app(&a)
    testing.expect(t, !os.exists(journal), "the journal outlived the exit that was clean")
}

// What is journaled is a descriptor read (§5): a file, and typing reaches it. A listing is
// neither, and journaling one would make every directory you opened recoverable work.
@(test)
only_editable_files_are_journaled :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-journal-who")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    a.home = strings.clone(home)

    file, _ := filepath.join({home, "alpha.txt"}, context.temp_allocator)
    app.ring_add(&a, listing_doc(&a, home)) // a file, and not editable
    editable := scratch_doc(&a, file, "ab")
    nameless := scratch_doc(&a, "", "cd") // editable, and no file to recover into
    app.docs_settle(&a)

    testing.expect(t, app.journal_detach(&a, editable), "the file was not journaled")
    testing.expect(t, !app.journal_detach(&a, nameless), "a document with no file was journaled")
    testing.expect_value(t, len(app.recover_scan(&a)), 1)
}

// The work reached its file before the crash. Offering it back is a decision that changes
// nothing, so the scan drops it and the page stays about what is actually at stake.
@(test)
recovery_drops_what_the_file_already_says :: proc(t: ^testing.T) {
    a, path, home, ok := crash_app(t, "oket-journal-saved", "one\n")
    if !ok {
        return
    }
    defer delete(home)
    defer delete(path)

    id := app.ring_focused(&a.ring).doc
    app.handle_chord(&a, chord("END"))
    app.text_input(&a, 'Z')
    saved := doc_text(&a, id)
    testing.expect_value(t, os.write_entire_file(path, transmute([]u8)saved), nil)
    testing.expect(t, app.journal_detach(&a, id), "the document was not being journaled")
    close_plug_app(&a)

    b, made := restart(home)
    if !testing.expect(t, made, "the restart made no App") {
        return
    }
    defer close_plug_app(&b)
    testing.expect_value(t, len(app.recover_scan(&b)), 0)
    testing.expect(t, !os.exists(app.journal_path(&b, path)), "a spent journal was kept")
}

// Two `notes.md` in two directories are two documents. A journal keyed on what was typed at
// `:open` would offer one back over the other, in whichever directory the next start ran from.
@(test)
a_journal_is_keyed_on_the_whole_path :: proc(t: ^testing.T) {
    cwd, _ := os.get_working_directory(context.temp_allocator)
    here, _ := filepath.join({cwd, "alpha.txt"}, context.temp_allocator)
    testing.expect_value(t, app.journal_name("alpha.txt"), app.journal_name(here))
    testing.expect(t, app.journal_name("one/alpha.txt") != app.journal_name("two/alpha.txt"),
                   "two directories shared one journal")
}

// --- the replay, on its own ---

// A torn tail is the normal way a journal ends: the process died mid-write. Everything before
// the torn record still has to come back.
@(test)
journal_survives_a_torn_tail :: proc(t: ^testing.T) {
    a, path, home, ok := crash_app(t, "oket-journal-torn", "abc")
    if !ok {
        return
    }
    defer delete(home)
    defer delete(path)

    id := app.ring_focused(&a.ring).doc
    app.handle_chord(&a, chord("END"))
    for r in "QR" {
        app.text_input(&a, r)
    }
    testing.expect(t, app.journal_detach(&a, id), "the document was not being journaled")
    journal := strings.clone(app.journal_path(&a, path), context.temp_allocator)
    whole, err := os.read_entire_file(journal, context.temp_allocator)
    if !testing.expect_value(t, err, nil) {
        close_plug_app(&a)
        return
    }
    full, full_text, full_ok := app.journal_replay(journal, context.temp_allocator)
    if !testing.expect(t, full_ok, "the intact journal did not replay") {
        close_plug_app(&a)
        return
    }

    // Chop a byte off: the last record is now short, and only it should be lost.
    testing.expect_value(t, os.write_entire_file(journal, whole[:len(whole) - 1]), nil)
    torn, torn_text, torn_ok := app.journal_replay(journal, context.temp_allocator)
    testing.expect(t, torn_ok, "a torn journal was refused outright")
    testing.expect_value(t, torn.edits, full.edits - 1)
    testing.expect(t, len(torn_text) > 0 && len(torn_text) < len(full_text),
                   "a torn journal recovered the whole tail, or none of it")
    close_plug_app(&a)
}

// Garbage is refused rather than replayed into a wrong document.
@(test)
journal_refuses_a_foreign_file :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-journal-junk")
    if !made {
        return
    }
    junk, _ := filepath.join({dir, "junk.okjrnl"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(junk, transmute([]u8)string("not a journal")),
                         nil)
    _, _, ok := app.journal_replay(junk, context.temp_allocator)
    testing.expect(t, !ok, "a non-journal file replayed")
}

// The replay parses lengths a crash (or an attacker) wrote: a record claiming more bytes than
// exist must end the replay, never index past the file or the document.
@(test)
journal_refuses_hostile_lengths :: proc(t: ^testing.T) {
    dir, made := scratch(t, "oket-journal-hostile")
    if !made {
        return
    }
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
        r, text, ok := app.journal_replay(file, context.temp_allocator)
        if !testing.expectf(t, ok, "record %d refused the whole journal, base and all", i) {
            continue
        }
        testing.expect_value(t, text, "ab") // the base survives, the lie does not
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

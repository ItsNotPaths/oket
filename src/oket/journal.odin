package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "../desc"
import "../store"
import "../txt"

// §10's recovery journal: every splice is appended to a per-document file as it lands, so
// recovery never depends on in-memory state surviving the crash. Nothing here serializes a
// piece table, because the piece table is what a crash is least entitled to trust.
//
// WHO IS JOURNALED IS A DESCRIPTOR READ, not a field: a document that names a `file` and takes
// typing has work on it that its file does not have yet, and that is the whole of what
// recovery is for. Stage 12 asked the same question about `watch` and answered it the other
// way, because reloading is the opener's; a journal is the kernel's own, and the kernel is
// what owns the text (§12).
//
// write() per splice only reaches the page cache, so a process crash loses nothing. fsync is
// the expensive half, debounced here, and the fault handler's whole job is one more fsync on
// bytes that are already written.

JOURNAL_DIR :: "journal" // beside the binary, next to binds.conf and plugins/
JOURNAL_EXT :: ".okjrnl"

@(private = "file")
MAGIC :: "okjrnl\x00\x00"
@(private = "file")
JOURNAL_VERSION :: 1
@(private = "file")
JOURNAL_SYNC :: 2 * time.Second

// Heap-allocated: the sink holds its address for as long as the document lives, and the map
// that owns it rehashes.
Journal :: struct {
    file:   ^os.File,
    path:   string, // owned; the journal file, not the document
    synced: time.Tick,
}

// Every frame, after the drain. Starting and stopping both live here rather than at the sites
// that open and close a document: what is journaled is a property of the descriptor, and the
// descriptor is what a transaction publishes.
journal_sync :: proc(a: ^App) {
    dir := journal_dir(a)
    // Collected first: journal_end deletes from the map, and walking one while it is being
    // written is a different bug every time (plug.odin says the same about `insts`).
    for id in journal_ids(a) {
        if dir == "" || !journal_wanted(a, id) {
            journal_end(a, id)
            continue
        }
        journal_pump(a.journals[id])
    }
    if dir == "" {
        return
    }
    for id in store.store_ids(&a.docs) {
        if id not_in a.journals && journal_startable(a, id) {
            journal_begin(a, id, dir)
        }
    }
}

// The document's journal is done: the slot is closing, or it stopped being work worth keeping.
// The file goes with it, or a later start would offer to recover what nobody is missing.
journal_end :: proc(a: ^App, id: store.Id) {
    j, journaled := a.journals[id]
    if !journaled {
        return
    }
    path := strings.clone(j.path, context.temp_allocator)
    journal_detach(a, id)
    os.remove(path)
}

// What a crash leaves behind: the descriptor goes and the bytes stay. journal_end adds the
// remove; a test calls this alone to write the half of the gate it cannot do to itself.
journal_detach :: proc(a: ^App, id: store.Id) -> bool {
    j, journaled := a.journals[id]
    if !journaled {
        return false
    }
    if doc := store.store_doc(&a.docs, id); doc != nil {
        doc.sink = {}
    }
    fault_journal_drop(os.fd(j.file))
    os.close(j.file)
    delete(j.path)
    free(j)
    delete_key(&a.journals, id)
    return true
}

// A clean exit is not a crash: the process is ending because it was asked to, so nothing it
// wrote is waiting to be recovered.
journals_destroy :: proc(a: ^App) {
    for id in journal_ids(a) {
        journal_end(a, id)
    }
    delete(a.journals)
    a.journals = nil
}

// The documents being journaled, as a slice: every walk over them may end one, and a map being
// written under an iterator is not a walk.
@(private = "file")
journal_ids :: proc(a: ^App) -> []store.Id {
    out := make([dynamic]store.Id, 0, len(a.journals), context.temp_allocator)
    for id in a.journals {
        append(&out, id)
    }
    return out[:]
}

// --- recovery ---

// What one journal file recovers to, minus the content: the home page lists these, and holding
// every recoverable document's text to draw a row would be the read path in the wrong place.
Recovered :: struct {
    journal: string, // owned; the journal file, which is what `:recover` names
    path:    string, // owned; the document it shadows
    edits:   int, // splices replayed, so a row can say how much is at stake
}

// Every journal left behind by a start that never got to clean up. A journal whose replay
// matches the file on disk is DROPPED here: the work was saved before the crash, and offering
// it back would be a page full of decisions that change nothing.
recover_scan :: proc(a: ^App, alloc := context.temp_allocator) -> []Recovered {
    out := make([dynamic]Recovered, alloc)
    dir := journal_dir(a)
    if dir == "" {
        return out[:]
    }
    infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
    if err != nil {
        return out[:]
    }
    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, JOURNAL_EXT) {
            continue
        }
        r, content, ok := journal_replay(info.fullpath, context.temp_allocator)
        if !ok {
            continue
        }
        disk, read := os.read_entire_file(r.path, context.temp_allocator)
        if read == nil && string(disk) == content {
            os.remove(info.fullpath)
            continue
        }
        append(&out, Recovered {
            journal = strings.clone(info.fullpath, alloc),
            path = strings.clone(r.path, alloc),
            edits = r.edits,
        })
    }
    return out[:]
}

// `:recover <journal>`: the document, opened the way `:open` opens one, and then the journal's
// bytes written over it. The kernel replays into a document a PLUGIN filled from the file, so
// the rule stage 8 set holds — the kernel still reads no file into a document of its own, and
// what it reads here is its own journal (§7, §10).
recover_apply :: proc(a: ^App, journal: string) -> bool {
    r, content, ok := journal_replay(journal, context.temp_allocator)
    if !ok {
        message_set(a, fmt.tprintf(":recover: %s is not a journal this build wrote", journal))
        return false
    }
    id, opened := open_path(a, r.path)
    if !opened {
        return false
    }
    ring_add(a, id)
    doc := store.store_doc(&a.docs, id)
    if doc == nil {
        return false
    }
    // One splice, with the sink off. Off because the journal is what is being replayed, and a
    // document that recovers itself into its own journal writes its history down twice; a
    // SPLICE because doc_set_text normalizes what it is given — a dropped trailing newline is
    // the crash's bytes edited on their way back in.
    doc.sink = {}
    txt.doc_apply(doc, {txt.Edit{0, txt.doc_len(doc), content, 0, 0}})
    txt.doc_forget_undo(doc)
    os.remove(journal)
    journal_end(a, id) // the next sync opens a fresh one, based on what was recovered
    message_set(a, fmt.tprintf(":recover: %s, %d edit(s) replayed", r.path, r.edits))
    return true
}

// `:recover drop <journal>`. The work was not wanted; the file on disk already says so.
recover_drop :: proc(a: ^App, journal: string) -> bool {
    if err := os.remove(journal); err != nil {
        message_set(a, fmt.tprintf(":recover: cannot remove %s: %v", journal, err))
        return false
    }
    return true
}

// --- the file ---

// Where journals live, "" when there is no home to put them in — which is what a test that
// does not care about recovery gets for free.
journal_dir :: proc(a: ^App) -> string {
    if a.home == "" {
        return ""
    }
    dir, _ := filepath.join({a.home, JOURNAL_DIR}, context.temp_allocator)
    return dir
}

// A document with unsaved work on it: it is a file, and typing reaches it (§5).
@(private = "file")
journal_wanted :: proc(a: ^App, id: store.Id) -> bool {
    d := store.store_descriptor(&a.docs, id)
    if d == nil {
        return false
    }
    defer desc.release(d)
    return d.editable && d.file != ""
}

// The same, and the file is one this document's TEXT could be written back to. A browser takes
// typing and names a directory, and a journal replaying a listing into one recovers nothing —
// so the two questions part company here rather than growing a descriptor field for it (§14).
//
// Only asked of a document that is not journaled yet, which is what keeps a stat off the frame
// loop for every buffer that already is.
@(private = "file")
journal_startable :: proc(a: ^App, id: store.Id) -> bool {
    if !journal_wanted(a, id) {
        return false
    }
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    // A path with nothing at it is a buffer whose file is not written yet, and that is exactly
    // the work worth keeping.
    info, err := os.stat(d.file, context.temp_allocator)
    return err != nil || info.type != .Directory
}

// Names the journal after the document it shadows. ABSOLUTE, because a descriptor's `file` is
// whatever was typed at it: two `notes.md` in two directories are two documents, and a relative
// path recovered from another start would open whichever one this cwd has. A path is not a
// filename either, so separators become underscores; the header carries the real path, and this
// only has to be unique.
journal_name :: proc(doc_path: string, alloc := context.temp_allocator) -> string {
    whole := path_abs(doc_path)
    b := strings.builder_make(alloc)
    for i in 0 ..< len(whole) {
        c := whole[i]
        strings.write_byte(&b, c == '/' || c == '\\' || c == ':' ? '_' : c)
    }
    strings.write_string(&b, JOURNAL_EXT)
    return strings.to_string(b)
}

// Where a document's journal is, whether or not one is open: the name is derived from the path
// (journal_name), which is what lets `:recover` name the DOCUMENT and find its journal.
journal_path :: proc(a: ^App, doc_path: string) -> string {
    dir := journal_dir(a)
    if dir == "" {
        return ""
    }
    path, _ := filepath.join({dir, journal_name(doc_path)}, context.temp_allocator)
    return path
}

// The base is the document's content right now, and recovery is that plus every later splice,
// so nothing downstream has to trust what is on disk.
@(private = "file")
journal_begin :: proc(a: ^App, id: store.Id, dir: string) {
    doc := store.store_doc(&a.docs, id)
    if doc == nil {
        return
    }
    if !os.exists(dir) && os.make_directory(dir) != nil {
        return
    }
    d := store.store_descriptor(&a.docs, id)
    defer desc.release(d)
    if d == nil {
        return
    }
    path, _ := filepath.join({dir, journal_name(d.file)}, context.allocator)
    // 0600: a journal holds the document's bytes, so it is as private as the document.
    f, err := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
    if err != nil {
        delete(path)
        return
    }
    if !write_header(f, path_abs(d.file), txt.doc_string(doc, context.temp_allocator)) {
        os.close(f)
        os.remove(path)
        delete(path)
        return
    }
    j := new(Journal)
    j^ = Journal{f, path, time.tick_now()}
    a.journals[id] = j
    fault_journal_add(os.fd(f))
    doc.sink = txt.Doc_Sink {
        user  = j,
        write = journal_write,
    }
}

// Debounced fsync. write() already put the bytes where a process crash cannot take them; this
// is for the machine losing power, and it is the only expensive call on the edit path.
@(private = "file")
journal_pump :: proc(j: ^Journal) {
    if time.tick_since(j.synced) < JOURNAL_SYNC {
        return
    }
    os.sync(j.file)
    j.synced = time.tick_now()
}

@(private = "file")
journal_write :: proc(user: rawptr, at, old_len: int, text: string) {
    j := (^Journal)(user)
    head: [24]u8
    endian.put_u64(head[0:8], .Little, u64(at))
    endian.put_u64(head[8:16], .Little, u64(old_len))
    endian.put_u64(head[16:24], .Little, u64(len(text)))
    os.write(j.file, head[:])
    if len(text) > 0 {
        os.write(j.file, transmute([]u8)text)
    }
}

@(private = "file")
write_header :: proc(f: ^os.File, doc_path, base: string) -> bool {
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, MAGIC)
    put_u32(&b, JOURNAL_VERSION)
    put_str(&b, doc_path)
    put_str(&b, base)
    _, err := os.write(f, transmute([]u8)strings.to_string(b))
    return err == nil
}

@(private = "file")
put_u32 :: proc(b: ^strings.Builder, v: u32) {
    buf: [4]u8
    endian.put_u32(buf[:], .Little, v)
    strings.write_bytes(b, buf[:])
}

@(private = "file")
put_str :: proc(b: ^strings.Builder, s: string) {
    buf: [8]u8
    endian.put_u64(buf[:], .Little, u64(len(s)))
    strings.write_bytes(b, buf[:])
    strings.write_string(b, s)
}

// Replays a journal file into the text it recovers to. A truncated tail is normal rather than
// an error: the process died mid-write, and everything before the torn record is still good.
journal_replay :: proc(file: string, alloc := context.allocator) ->
                       (r: Recovered, content: string, ok: bool) {
    raw, err := os.read_entire_file(file, context.temp_allocator)
    if err != nil {
        return
    }
    data := raw
    if len(data) < len(MAGIC) + 4 || string(data[:len(MAGIC)]) != MAGIC {
        return
    }
    at := len(MAGIC)
    version, _ := endian.get_u32(data[at:at + 4], .Little)
    if version != JOURNAL_VERSION {
        return
    }
    at += 4

    doc_path := take_str(data, &at) or_return
    base := take_str(data, &at) or_return

    text := strings.clone(base, context.temp_allocator)
    edits := 0
    for at + 24 <= len(data) {
        pos, _ := endian.get_u64(data[at:at + 8], .Little)
        old_len, _ := endian.get_u64(data[at + 8:at + 16], .Little)
        new_len, _ := endian.get_u64(data[at + 16:at + 24], .Little)
        at += 24
        // Compared as u64: these came off the disk, and a cast first would wrap a hostile
        // length into a small int that passes.
        if new_len > u64(len(data) - at) {
            break // torn write; keep what came before it
        }
        ins := string(data[at:at + int(new_len)])
        at += int(new_len)
        if pos > u64(len(text)) || old_len > u64(len(text)) - pos {
            break // the record does not fit the document it claims to edit
        }
        text = strings.concatenate(
            {text[:pos], ins, text[pos + old_len:]},
            context.temp_allocator,
        )
        edits += 1
    }
    return Recovered {
            journal = strings.clone(file, alloc),
            path = strings.clone(doc_path, alloc),
            edits = edits,
        },
        strings.clone(text, alloc),
        true
}

@(private = "file")
take_str :: proc(data: []u8, at: ^int) -> (s: string, ok: bool) {
    if at^ + 8 > len(data) {
        return
    }
    n, _ := endian.get_u64(data[at^:at^ + 8], .Little)
    at^ += 8
    if n > u64(len(data) - at^) { // u64, so a hostile length cannot wrap the check
        return
    }
    s = string(data[at^:at^ + int(n)])
    at^ += int(n)
    return s, true
}

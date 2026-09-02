package edit

import "core:encoding/endian"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "../txt"

// §10's recovery journal: every splice is appended to a per-buffer file as it is applied, so
// recovery never depends on in-memory state surviving the crash. The piece table may be
// exactly what got corrupted, which is why nothing here serializes it.
//
// write() per splice only reaches the page cache, so a process crash loses nothing. fsync is
// the expensive half, debounced here, and the crash handler's whole job is one more fsync on
// bytes that are already written.

@(private = "file")
MAGIC :: "okjrnl\x00\x00"
JOURNAL_VERSION :: 1
JOURNAL_SYNC :: 2 * time.Second

// Set by the kernel so an open journal's descriptor reaches the crash handler. `edit` cannot
// import `oket`, and this is the shape `pty.wake` already uses.
journal_opened: proc(fd: uintptr)
journal_closed: proc(fd: uintptr)

// Where journals are written. Set once by the kernel; "" turns journaling off, which is what a
// test that does not care about recovery gets for free.
journal_dir: string

Journal :: struct {
    file:   ^os.File,
    path:   string, // owned; the journal file, not the document
    synced: time.Tick,
}

// Names the journal after the document it shadows. A path is not a filename, so separators
// become underscores; the header carries the real path, and this only has to be unique.
journal_name :: proc(doc_path: string, alloc := context.temp_allocator) -> string {
    if doc_path == "" {
        return strings.clone("scratch.okjrnl", alloc)
    }
    b := strings.builder_make(alloc)
    for i in 0 ..< len(doc_path) {
        c := doc_path[i]
        strings.write_byte(&b, c == '/' || c == '\\' || c == ':' ? '_' : c)
    }
    strings.write_string(&b, ".okjrnl")
    return strings.to_string(b)
}

// Starts (or restarts) journaling `b` into `dir`. `base` is the buffer's content right now,
// which the caller guarantees is the clean state: recovery is that plus every later splice, so
// it never has to trust what is on disk.
journal_begin :: proc(b: ^Buffer, dir: string) -> bool {
    journal_end(b)
    if dir == "" {
        return false
    }
    if !os.exists(dir) && os.make_directory(dir) != nil {
        return false
    }
    path, _ := filepath.join({dir, journal_name(b.path)}, context.allocator)
    // 0600: a journal holds the document's bytes, so it is as private as the document.
    f, err := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
    if err != nil {
        delete(path)
        return false
    }
    b.journal = Journal {
        file   = f,
        path   = path,
        synced = time.tick_now(),
    }
    // doc_string, not buffer_bytes: the sink's offsets are document coordinates, and
    // buffer_bytes appends the trailing newline that save restores.
    if !write_header(f, b.path, txt.doc_string(&b.doc, context.temp_allocator)) {
        journal_end(b)
        return false
    }
    if journal_opened != nil {
        journal_opened(os.fd(f))
    }
    b.doc.sink = txt.Doc_Sink {
        user  = b,
        write = journal_write,
    }
    return true
}

// Closes and removes the journal: the document on disk now says what the journal said, and a
// leftover file would offer to recover work that is already saved.
journal_end :: proc(b: ^Buffer) {
    if b.journal.file == nil {
        return
    }
    path := strings.clone(b.journal.path, context.temp_allocator) // detach frees the original
    journal_detach(b)
    os.remove(path)
}

// Stops journaling but leaves the file, which is what a crash does: the descriptor goes and
// the bytes stay. Returns false when there was no journal.
journal_detach :: proc(b: ^Buffer) -> bool {
    j := &b.journal
    if j.file == nil {
        return false
    }
    b.doc.sink = {}
    if journal_closed != nil {
        journal_closed(os.fd(j.file))
    }
    os.close(j.file)
    delete(j.path)
    j^ = {}
    return true
}

// Debounced fsync. write() already put the bytes where a process crash cannot take them; this
// is for the machine losing power, and it is the only expensive call on the edit path.
journal_pump :: proc(b: ^Buffer) {
    j := &b.journal
    if j.file == nil || time.tick_since(j.synced) < JOURNAL_SYNC {
        return
    }
    os.sync(j.file)
    j.synced = time.tick_now()
}

@(private = "file")
journal_write :: proc(user: rawptr, at, old_len: int, text: string) {
    b := (^Buffer)(user)
    if b.journal.file == nil {
        return
    }
    head: [24]u8
    endian.put_u64(head[0:8], .Little, u64(at))
    endian.put_u64(head[8:16], .Little, u64(old_len))
    endian.put_u64(head[16:24], .Little, u64(len(text)))
    os.write(b.journal.file, head[:])
    if len(text) > 0 {
        os.write(b.journal.file, transmute([]u8)text)
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

// What one journal file recovers to.
Recovered :: struct {
    path:    string, // owned; the document, "" for a scratch buffer
    content: string, // owned
    edits:   int, // splices replayed, so the notice can say how much was at stake
}

// Replays a journal file. A truncated tail is normal rather than an error: the process died
// mid-write, and everything before the torn record is still good.
journal_recover :: proc(file: string, alloc := context.allocator) -> (r: Recovered, ok: bool) {
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
            path = strings.clone(doc_path, alloc),
            content = strings.clone(text, alloc),
            edits = edits,
        },
        true
}

recovered_destroy :: proc(r: ^Recovered) {
    delete(r.path)
    delete(r.content)
    r^ = {}
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

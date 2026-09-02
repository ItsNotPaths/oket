package edit

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "../txt"

// FILE state over a Doc: path, dirtiness, line endings, the disk stamp and the conflict flag.
// View state (scroll) lives with the surface that draws the buffer (§12), so this package
// tests without a window and a reload cannot know or care what is on screen.

Buffer :: struct {
    using doc:     txt.Doc,
    path:          string, // owned; "" = unnamed scratch
    dirty:         bool,
    final_newline: bool, // did the file end in '\n'? preserved on save
    crlf:          bool, // did the file break its lines with "\r\n"? restored on save
    disk_mtime:    time.Time, // mtime at our last load/save; detects external rewrites
    conflict:      bool, // the file changed on disk under unsaved edits; a decision is pending
    journal:       Journal, // §10's recovery journal; zero when not journaled
}

buffer_init :: proc(b: ^Buffer) {
    txt.doc_init(&b.doc)
    b.final_newline = true
}

buffer_destroy :: proc(b: ^Buffer) {
    journal_end(b)
    txt.doc_destroy(&b.doc)
    delete(b.path)
}

buffer_set_text :: proc(b: ^Buffer, text: string) {
    txt.doc_set_text(&b.doc, text)
}

buffer_load :: proc(b: ^Buffer, path: string) -> bool {
    src, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil {
        return false
    }
    content := string(src)
    // Everything derived from `path` BEFORE freeing the old b.path: a reload passes b.path
    // itself, so freeing first would clone and stat freed memory.
    new_path := strings.clone(path)
    mtime := file_mtime(path) or_else time.Time{}
    buffer_set_text(b, content)
    delete(b.path)
    b.path = new_path
    b.dirty = false
    b.final_newline = strings.has_suffix(content, "\n")
    b.crlf = crlf_file(content)
    b.disk_mtime = mtime
    journal_begin(b, journal_dir) // a fresh base: everything after this is recoverable
    return true
}

// A missing file opens empty and is created by the first save; an unreadable one is an error.
buffer_open :: proc(b: ^Buffer, path: string) -> bool {
    if buffer_load(b, path) {
        return true
    }
    if _, exists := file_mtime(path); exists {
        return false
    }
    delete(b.path)
    b.path = strings.clone(path)
    return true
}

// The precondition every disk op shares. False for a scratch buffer.
buffer_on_disk :: proc(b: ^Buffer) -> bool {
    return b.path != ""
}

// `.Denied` is the only failure with a way forward (a staged sudo save, later), so it is the
// only one callers act on rather than report.
Save_Result :: enum {
    Ok,
    No_Path, // unnamed scratch
    Denied, // EACCES / EPERM, on the file or on its folder
    Failed, // a full disk, a vanished folder, an I/O error
}

// Lines joined by '\n', the trailing newline back if the loaded file had one, and every break
// back to "\r\n" if that is how the file wrote them.
buffer_bytes :: proc(b: ^Buffer, allocator := context.temp_allocator) -> string {
    data := txt.doc_string(&b.doc, allocator)
    if b.final_newline {
        with_nl := strings.concatenate({data, "\n"}, allocator)
        delete(data, allocator)
        data = with_nl
    }
    if !b.crlf {
        return data
    }
    out, replaced := strings.replace_all(data, "\n", "\r\n", allocator)
    if replaced { // a one-line file with no break returns `data` itself
        delete(data, allocator)
    }
    return out
}

// A file breaks its lines the way its FIRST break does; a mixed file is saved the one way. The
// load strips every '\r' (doc_normalize), so this is the only chance to see them.
crlf_file :: proc(text: string) -> bool {
    i := strings.index_byte(text, '\n')
    return i > 0 && text[i - 1] == '\r'
}

buffer_save :: proc(b: ^Buffer) -> Save_Result {
    if !buffer_on_disk(b) {
        return .No_Path
    }
    res := file_write_atomic(b.path, buffer_bytes(b))
    if res == .Ok {
        buffer_mark_saved(b)
        // Here, because a save has just read the whole document anyway and holds no borrowed
        // span across it.
        txt.doc_maintain(&b.doc)
    }
    return res
}

// Save-as: the buffer ADOPTS the path, so the bar, the next `:w`, the staleness stamp and the
// journal all follow the file the work is now in. A failed write changes nothing, including
// which file the buffer belongs to.
buffer_save_as :: proc(b: ^Buffer, path: string) -> Save_Result {
    if path == "" {
        return .No_Path
    }
    old := b.path
    b.path = strings.clone(path)
    res := buffer_save(b)
    if res != .Ok {
        delete(b.path)
        b.path = old
        return res
    }
    delete(old) // buffer_save re-journalled under the new name, and journal_begin took the old
    return res
}

// THE FILE IS NEVER TRUNCATED: the bytes go to a sibling temp file, reach the platter, and the
// rename swings the name over in one step. A crash, a full disk or a kill loses the save, never
// the file. Sibling because rename is only atomic inside one filesystem.
file_write_atomic :: proc(path: string, data: string) -> Save_Result {
    target := file_link_target(path) // save THROUGH a symlink; a rename would replace the link
    // The temp file is written in the folder, so the folder's rights are all the write tests.
    // A read-only FILE has to be asked about directly, or `chmod 444` would not hold.
    if f, err := os.open(target, {.Write}); err == nil {
        os.close(f)
    } else if err == .Permission_Denied {
        return .Denied
    }
    perm := os.Permissions_Read_All + {.Write_User}
    if fi, err := os.stat(target, context.temp_allocator); err == nil {
        perm = fi.mode // the file keeps its own bits, not a fresh file's defaults
    }
    // pid + a counter, in the target's folder: short, because a name built from the file's own
    // would run past NAME_MAX on a long one, and unique, so two saves cannot take each other's.
    seq := sync.atomic_add(&save_tmp_seq, 1)
    name := fmt.tprintf(".oket-%d-%d.tmp", os.get_pid(), seq)
    tmp := filepath.join({filepath.dir(target), name}, context.temp_allocator) or_else ""
    if tmp == "" {
        return .Failed
    }
    err := file_write_synced(tmp, data, perm)
    if err == nil {
        err = os.rename(tmp, target)
    }
    if err != nil {
        os.remove(tmp) // nothing half-written is left behind
        // EACCES and EPERM both arrive as Permission_Denied. EROFS does not: a read-only mount
        // is not a door sudo can open.
        return err == .Permission_Denied ? .Denied : .Failed
    }
    return .Ok
}

@(private = "file")
save_tmp_seq: int

// Written AND flushed to stable storage, so the rename cannot publish a name whose bytes are
// still in flight.
@(private = "file")
file_write_synced :: proc(path: string, data: string, perm: os.Permissions) -> os.Error {
    f, err := os.open(path, {.Write, .Create, .Trunc}, perm)
    if err != nil {
        return err
    }
    defer os.close(f)
    n := os.write(f, transmute([]u8)data) or_return
    if n != len(data) {
        return .Short_Write
    }
    return os.sync(f)
}

// What `path` finally points at, so the save lands on the file rather than on the link. Returns
// `path` itself when it is not a link, and gives up after a few hops rather than chase a loop.
@(private = "file")
file_link_target :: proc(path: string) -> string {
    out := path
    for _ in 0 ..< 8 {
        dst, err := os.read_link(out, context.temp_allocator)
        if err != nil {
            break
        }
        if filepath.is_abs(dst) {
            out = dst
        } else {
            out = filepath.join({filepath.dir(out), dst}, context.temp_allocator) or_else out
        }
    }
    return out
}

// Clean, unconflicted, stamped with the file's current mtime so the staleness check does not
// read our own write back as somebody else's.
buffer_mark_saved :: proc(b: ^Buffer) {
    b.dirty = false
    b.conflict = false // our write IS the disk now
    b.disk_mtime = file_mtime(b.path) or_else {}
    journal_begin(b, journal_dir) // the old journal recovers work that is now on disk
}

// The bytes the buffer WOULD write, compared against the file. What lets a builtin that marks
// work clean be safe to type anywhere.
buffer_matches_disk :: proc(b: ^Buffer) -> bool {
    if !buffer_on_disk(b) {
        return false
    }
    disk, err := os.read_entire_file_from_path(b.path, context.temp_allocator)
    return err == nil && string(disk) == buffer_bytes(b)
}

// ok=false when it cannot be stat'd. The one staleness stamp.
file_mtime :: proc(path: string) -> (time.Time, bool) {
    fi, err := os.stat(path, context.temp_allocator)
    if err != nil {
        return {}, false
    }
    return fi.modification_time, true
}

// So a later save cannot clobber an external tool's edits. A clean buffer reloads silently; a
// dirty one is a conflict, and `prompt_on_conflict` raises it without adopting the stamp.
buffer_reload_if_changed :: proc(b: ^Buffer, prompt_on_conflict: bool) -> bool {
    if !buffer_on_disk(b) {
        return false
    }
    mt := file_mtime(b.path) or_else b.disk_mtime // unreadable: treat as unchanged
    if mt == b.disk_mtime {
        return false
    }
    if b.dirty {
        if prompt_on_conflict {
            b.conflict = true // ask, do not clobber
        } else {
            b.disk_mtime = mt // relaxed: keep my edits, accept the new stamp
        }
        return false
    }
    b.disk_mtime = mt
    return buffer_reload_keep_cursor(b)
}

// Holds the caret across the swap, clamped to the new length, so a background edit does not
// yank it to the origin. The view clamps its own scroll next frame.
buffer_reload_keep_cursor :: proc(b: ^Buffer) -> bool {
    if !buffer_on_disk(b) {
        return false
    }
    head := b.cursors[b.primary].head
    if !buffer_load(b, b.path) {
        return false
    }
    txt.doc_reset_cursor(&b.doc, head) // clamped onto the reloaded content
    return true
}

// Throw the unsaved edits away and take the disk version back. Reload first: until it lands,
// the edits in hand are the only copy there is.
buffer_discard :: proc(b: ^Buffer) -> bool {
    if !buffer_on_disk(b) || !buffer_reload_keep_cursor(b) {
        return false
    }
    b.dirty = false
    b.conflict = false // the disk is what we hold now, so there is nothing left to settle
    return true
}

// reload=true takes the disk version; false keeps the edits and adopts the current stamp, so
// the prompt stays down until the file changes again. Either clears the conflict.
buffer_conflict_resolve :: proc(b: ^Buffer, reload: bool) {
    b.conflict = false
    if reload {
        buffer_discard(b)
    } else {
        b.disk_mtime = file_mtime(b.path) or_else b.disk_mtime // cache "keep mine"
    }
}

// --- editing (thin wrappers over the Doc core; mark the buffer dirty) ---

buffer_insert_rune :: proc(b: ^Buffer, r: rune) {
    b.dirty |= txt.doc_insert_rune(&b.doc, r)
}

buffer_insert_text :: proc(b: ^Buffer, text: string) {
    b.dirty |= txt.doc_insert_text(&b.doc, text)
}

buffer_newline :: proc(b: ^Buffer) {
    b.dirty |= txt.doc_newline(&b.doc)
}

buffer_backspace :: proc(b: ^Buffer) {
    b.dirty |= txt.doc_backspace(&b.doc)
}

buffer_delete :: proc(b: ^Buffer) {
    b.dirty |= txt.doc_delete(&b.doc)
}

buffer_delete_word_back :: proc(b: ^Buffer) {
    b.dirty |= txt.doc_delete_word_back(&b.doc)
}

buffer_delete_word_forward :: proc(b: ^Buffer) {
    b.dirty |= txt.doc_delete_word_forward(&b.doc)
}

buffer_cut :: proc(b: ^Buffer) {
    b.dirty |= txt.doc_cut(&b.doc)
}

buffer_paste :: proc(b: ^Buffer, text: string) {
    b.dirty |= txt.doc_paste(&b.doc, text)
}

// One piece per cursor, in document order; the caller has checked the counts agree.
buffer_paste_pieces :: proc(b: ^Buffer, pieces: []string) {
    b.dirty |= txt.doc_paste_pieces(&b.doc, pieces)
}

buffer_replace_all :: proc(b: ^Buffer, pattern, with: string) -> int {
    n := txt.doc_replace_all(&b.doc, pattern, with)
    b.dirty |= n > 0
    return n
}

buffer_undo :: proc(b: ^Buffer) {
    if txt.doc_undo(&b.doc) {
        b.dirty = true
    }
}

buffer_redo :: proc(b: ^Buffer) {
    if txt.doc_redo(&b.doc) {
        b.dirty = true
    }
}

buffer_motion :: proc(b: ^Buffer, motion: txt.Motion, select := false) {
    txt.doc_move(&b.doc, motion, select)
}

package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "../desc"
import "../store"
import app "../oket"

// plugins/grep's `:grep`: grep's matches as a document in the `grep` lane, a block per match,
// down steps a block, and enter opens the file at the line.

@(private = "file")
write :: proc(t: ^testing.T, dir, name, text: string) -> string {
    path, _ := filepath.join({dir, name}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil, path)
    return path
}

// Pumps until the search has ended and its document says so.
@(private = "file")
searched :: proc(a: ^app.App) -> bool {
    for _ in 0 ..< 1000 {
        app.plug_pump(a)
        app.docs_settle(a)
        if text := focused_text(a); text != "" && !strings.has_prefix(text, "searching") {
            return true
        }
        time.sleep(5 * time.Millisecond)
    }
    return false
}

@(private = "file")
caret_line :: proc(a: ^app.App) -> int {
    doc := store.store_doc(a.docs, app.ring_focused(a).doc)
    return doc.cursors[doc.primary].head.line
}

@(test)
grep_lists_blocks_steps_them_and_opens_the_match :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-grep", "plugins/grep", "plugins/edit")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    for name in ([]string{"grep", "edit"}) {
        if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, name)), a.message) {
            return
        }
    }
    app.binds_sync(&a) // the rows the plugins asked for, into binds.conf and the table
    dir := home_dir(a.home)
    write(t, dir, "one.txt", "a\nneedle here\nb\n")
    write(t, dir, "two.txt", "x\ny\nz\nw\nneedle again\n")

    app.cl_exec(&a, fmt.tprintf(":grep needle %s", dir))
    if !testing.expect(t, searched(&a), "the search never ended") {
        return
    }
    kind, _ := app.kind_named(&a, "grep")
    testing.expect_value(t, app.doc_kind(&a, app.ring_focused(&a).doc), kind)
    text := focused_text(&a)
    testing.expect(t, strings.has_prefix(text, "2 matches for needle"), text)
    testing.expect(t, strings.contains(text, "     2> needle here"), text)

    // The caret starts on the first block's header; down is the second one.
    first := caret_line(&a)
    app.handle_chord(&a, chord("DOWN"))
    testing.expect(t, caret_line(&a) > first + 1, "down moved less than a block")
    app.handle_chord(&a, chord("UP"))
    testing.expect_value(t, caret_line(&a), first)

    // Enter on the header opens the file it names, with the caret on the match.
    header := strings.split_lines(text, context.temp_allocator)[first]
    colon := strings.last_index_byte(header, ':')
    want_line, _ := strconv.parse_int(header[colon + 1:])
    app.handle_chord(&a, chord("RTRN"))
    d := store.store_descriptor(a.docs, app.ring_focused(&a).doc)
    defer desc.release(d)
    if testing.expect(t, d != nil) {
        testing.expect_value(t, d.file, header[:colon])
        testing.expect_value(t, caret_line(&a), want_line - 1)
    }
}

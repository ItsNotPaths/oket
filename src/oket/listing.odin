package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../desc"
import "../store"

// The one document the kernel opens with no plugins loaded (stage 3). A directory listing is
// the smallest thing that needs a descriptor: the renderer that draws it is the renderer that
// draws a file, and a bind asking for `<path>` reads a row's field rather than calling back
// into whoever built the listing.

// The columns the listing shows, and the field names its rows carry: one source, so a bind
// asking for `<path>` and the column headed "path" can never drift apart.
@(private = "file")
COLUMNS :: [?]desc.Column{{"path", 28, .Left}, {"kind", 4, .Left}, {"size", 9, .Right}}

// One row per entry, tab-separated, with each column's span recorded as a field. The separator
// is arbitrary: the descriptor says where the fields are, so nothing downstream parses this
// text again.
listing_open :: proc(s: ^store.Store, dir: string) -> store.Id {
    infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
    if err != nil {
        return store.store_open(s, fmt.tprintf("cannot read %s: %v", dir, err))
    }
    slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

    columns := COLUMNS
    text := strings.builder_make(context.temp_allocator)
    fields := make([dynamic]desc.Field, context.temp_allocator)
    for info, line in infos {
        if line > 0 {
            strings.write_rune(&text, '\n')
        }
        is_dir := info.type == .Directory
        cells := [?]string{info.name, is_dir ? "dir" : "file", is_dir ? "" : fmt.tprintf("%d", info.size)}
        at := 0
        for cell, i in cells {
            if i > 0 {
                strings.write_rune(&text, '\t')
                at += 1
            }
            strings.write_string(&text, cell)
            append(&fields, desc.Field{line, columns[i].name, at, at + len(cell)})
            at += len(cell)
        }
    }

    id := store.store_open(s, strings.to_string(text))
    gen, _ := store.store_gen(s, id)
    // `surface`, not `text`: a listing's keys are a surface's, so `enter` here and `enter` in an
    // editor are two rows rather than one mode. Rows are what it selects, which is the drag
    // granularity as well (§5, §8).
    d := desc.new_from(
        {
            numbers = .Absolute,
            ctx = .Surface,
            selection = .Line,
            tab_width = 4,
            columns = columns[:],
            fields = fields[:],
        },
    )
    store.store_submit(s, id, gen, nil, d)
    desc.release(d)
    store.store_drain(s)
    return id
}

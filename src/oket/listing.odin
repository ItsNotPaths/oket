package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../desc"
import "../store"

// The one document the kernel opens with no plugins loaded (stage 3). A directory listing is
// the smallest thing that needs a descriptor: the renderer that draws it is the renderer that
// draws a file, and a bind asking for `<path>` reads a row's field rather than calling back
// into whoever built the listing.

// What the listing SHOWS. `path` is not among them: a row acts on the full path a bind hands
// on, and the visible `name` is its tail sub-span, which is what hover underlines.
@(private = "file")
COLUMNS :: [?]desc.Column{{"name", 28, .Left}, {"kind", 4, .Left}, {"size", 9, .Right}}

// One row per entry, tab-separated, with each column's span recorded as a field. The separator
// is arbitrary: the descriptor says where the fields are, so nothing downstream parses this
// text again.
listing_open :: proc(a: ^App, dir: string) -> store.Id {
    s := &a.docs
    columns := COLUMNS
    text := strings.builder_make(context.temp_allocator)
    fields := make([dynamic]desc.Field, context.temp_allocator)

    // A directory that will not read is still a listing, and it still says which one: the
    // descriptor goes on either way, or a failed read would hand back a document of no kind and
    // the lane it was opened in would lose it.
    infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
    if err != nil {
        strings.write_string(&text, fmt.tprintf("cannot read %s: %v", dir, err))
        infos = nil
    }
    slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

    for info, line in infos {
        if line > 0 {
            strings.write_rune(&text, '\n')
        }
        is_dir := info.type == .Directory
        full, _ := filepath.join({dir, info.name}, context.temp_allocator)
        size := is_dir ? "" : fmt.tprintf("%d", info.size)
        cells := [?]string{full, is_dir ? "dir" : "file", size}
        at := 0
        for cell, i in cells {
            if i > 0 {
                strings.write_rune(&text, '\t')
                at += 1
            }
            strings.write_string(&text, cell)
            if i == 0 {
                // Two fields over one cell: the path is the whole of it, the name its tail.
                append(&fields, desc.Field{line, "path", at, at + len(cell)})
                append(&fields, desc.Field{line, "name", at + len(cell) - len(info.name),
                                           at + len(cell)})
            } else {
                append(&fields, desc.Field{line, columns[i].name, at, at + len(cell)})
            }
            at += len(cell)
        }
    }

    id := store.store_open(s, strings.to_string(text))
    gen, _ := store.store_gen(s, id)
    // `surface`, not `text`: a listing's keys are a surface's, so `enter` here and `enter` in an
    // editor are two rows rather than one mode. Rows are what it selects, which is the drag
    // granularity as well (§5, §8). Not editable: a listing is not a text field.
    d := desc.new_from(
        {
            numbers = .Absolute,
            ctx = kind_ctx(a, KIND_FILES),
            kind = KIND_FILES,
            file = dir,
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

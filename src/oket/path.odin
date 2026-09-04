package main

import "core:os"
import "core:path/filepath"

// A path, canonical. The kernel compares two paths in two places — `:open` asks whether a file
// is already open (`ring_file`) and the journal keys a document by where it lives — and both
// come through here, so the two cannot drift about whether `./x` and `x` are one file.

// Lexical rather than `filepath.abs`, which resolves and so answers nothing for a file that does
// not exist yet: a buffer over a new file is exactly the work most worth journaling.
// Temp-allocated.
path_abs :: proc(path: string) -> string {
    if path == "" {
        return ""
    }
    if filepath.is_abs(path) {
        whole, _ := filepath.clean(path, context.temp_allocator)
        return whole == "" ? path : whole
    }
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        return path
    }
    whole, _ := filepath.join({cwd, path}, context.temp_allocator)
    return whole == "" ? path : whole
}

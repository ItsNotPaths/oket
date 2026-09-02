#+build windows
package gfx

import "core:os"

// Read whole for now; CreateFileMapping/MapViewOfFile is the port when it happens.

@(private)
face_map :: proc(path: string) -> (data: []u8, ok: bool) {
    d, err := os.read_entire_file(path, context.allocator)
    if err != nil || len(d) == 0 {
        return nil, false
    }
    return d, true
}

@(private)
face_unmap :: proc(data: []u8) {
    delete(data)
}

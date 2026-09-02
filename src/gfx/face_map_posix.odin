#+build linux, darwin, netbsd, openbsd, freebsd
package gfx

import "core:c"
import "core:strings"
import "core:sys/posix"

// Font files are mapped, not read: a CJK face is ~19 MB of mostly-untouched outlines, and
// stbtt only reads through the pointer, so the OS pages in what is actually used.

@(private)
face_map :: proc(path: string) -> (data: []u8, ok: bool) {
    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    fd := posix.open(cpath, {}) // O_RDONLY is 0, so an empty flag set is read-only
    if fd < 0 {
        return nil, false
    }
    defer posix.close(fd)

    st: posix.stat_t
    if posix.fstat(fd, &st) != .OK || st.st_size <= 0 {
        return nil, false
    }
    n := int(st.st_size)
    p := posix.mmap(nil, c.size_t(n), {.READ}, {.PRIVATE}, fd, 0)
    if p == nil || p == rawptr(~uintptr(0)) { // MAP_FAILED
        return nil, false
    }
    return (cast([^]u8)p)[:n], true
}

@(private)
face_unmap :: proc(data: []u8) {
    if len(data) > 0 {
        posix.munmap(raw_data(data), c.size_t(len(data)))
    }
}

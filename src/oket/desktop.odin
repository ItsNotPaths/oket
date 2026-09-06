package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The launcher entry, which an install files and an uninstall takes away (INSTALL.md §5). The
// template is #load-ed, so the binary carries what it writes and there is no file to lose.

DESKTOP_SRC := string(#load("../../oket.desktop"))
DESKTOP_ICON_SRC := string(#load("../../assets/oketpus.svg"))

DESKTOP_NAME :: "oket.desktop" // <app-id>.desktop, which is what ties a window to its entry

// Both off $XDG_DATA_HOME but NOT off oket's folder in it: applications/ and icons/ are shared
// trees every launcher reads, and a file under oket/ is invisible to all of them. hicolor is the
// theme every icon theme inherits from, and scalable/ is where an SVG goes.
DESKTOP_REL :: "applications"
ICON_REL :: "icons/hicolor/scalable/apps"

// `Icon=oket` in the entry resolves BY NAME through the icon theme, so the file is named for the
// app and not for the drawing in the repo.
ICON_NAME :: "oket.svg"

// "" with no $HOME, which every caller here refuses on.
desktop_path :: proc(allocator := context.allocator) -> string {
    return desktop_under(DESKTOP_REL, DESKTOP_NAME, allocator)
}

icon_path :: proc(allocator := context.allocator) -> string {
    return desktop_under(ICON_REL, ICON_NAME, allocator)
}

@(private = "file")
desktop_under :: proc(rel, name: string, allocator := context.allocator) -> string {
    data := xdg_data_home(context.temp_allocator)
    if data == "" {
        return strings.clone("", allocator)
    }
    path, _ := filepath.join({data, rel, name}, allocator)
    return path
}

// Best effort, and separate from the entry: an entry with no icon still launches and still says
// what it is, so a failed icon reported as a failed add would hide the entry that DID land.
icon_add :: proc(path: string) -> bool {
    if path == "" {
        return false
    }
    _ = os.make_directory_all(filepath.dir(path)) // a slice of path
    return os.write_entire_file(path, transmute([]u8)DESKTOP_ICON_SRC) == nil
}

icon_remove :: proc(path: string) -> bool {
    return path != "" && os.exists(path) && os.remove(path) == nil
}

// Replacing whatever is there. Unlike config.conf this file is not yours to edit: it is
// generated from the binary you are running, so a second install after a move refreshes it.
desktop_add :: proc(path, exe: string) -> bool {
    if path == "" {
        return false
    }
    _ = os.make_directory_all(filepath.dir(path)) // a slice of path
    body := desktop_text(DESKTOP_SRC, exe, context.temp_allocator)
    if os.write_entire_file(path, transmute([]u8)body) != nil {
        return false
    }
    desktop_reindex(filepath.dir(path)) // a slice of path
    return true
}

desktop_remove :: proc(path: string) -> bool {
    if path == "" || !os.exists(path) || os.remove(path) != nil {
        return false
    }
    desktop_reindex(filepath.dir(path)) // a slice of path
    return true
}

// The template with its command word replaced by an absolute path. A desktop entry is launched
// with the session's PATH, and ~/.local/bin is not always on it.
//
// Pure, so the suite can check the substitution with no $HOME and no launcher. Everything the
// template says that is not one of these two lines is copied through as it stands.
desktop_text :: proc(src, exe: string, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(src) + 2 * len(exe), allocator)
    rest := src
    for line in strings.split_lines_iterator(&rest) {
        switch {
        case strings.has_prefix(line, "Exec="):
            // The path, then whatever followed the command word: `%F` is what a launcher
            // substitutes the opened paths into, and rewriting the whole line would drop it.
            fmt.sbprintf(&b, "Exec=%s%s", exe, desktop_tail(line))
        case strings.has_prefix(line, "TryExec="):
            fmt.sbprintf(&b, "TryExec=%s", exe)
        case:
            strings.write_string(&b, line)
        }
        strings.write_byte(&b, '\n')
    }
    return strings.to_string(b)
}

// Everything after the command word in an `Exec=` line, its leading space included, or "".
@(private = "file")
desktop_tail :: proc(line: string) -> string {
    value := line[len("Exec="):]
    i := strings.index_byte(value, ' ')
    return i < 0 ? "" : value[i:]
}

// Most launchers read the directory itself; the ones that cache miss a new entry until this
// runs. The result is discarded: the command is absent on plenty of machines, and that is not a
// failure of the write that already landed.
@(private = "file")
desktop_reindex :: proc(dir: string) {
    // The directory travels as $1 and is never re-parsed as shell syntax.
    argv := []string {
        "sh", "-c",
        `command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$1"`,
        "sh", dir,
    }
    _, _, _, _ = os.process_exec({command = argv}, context.temp_allocator)
}

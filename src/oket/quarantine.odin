package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The other half of §10's net, and the half stage 9 left: a plugin that dies IN a window the
// net cannot unwind takes the process with it, so the next start is the only place that can
// notice. Two pieces, and the split is what makes it work at all:
//
//   THE HANDLER WRITES THE REPORT. One `write` of a name it copied at arm time, to an fd that
//   was opened while the process was healthy (fault.odin). It cannot allocate, open a file or
//   format, so anything richer than a name is a report that never gets written.
//
//   THE SWEEP READS IT. At startup, before autoload, so a plugin that crashed the last run is
//   not loaded into this one. Quarantine is across STARTS and never within one: inside a
//   session the net already unloads and names a faulted plugin, and the loop a plugin author is
//   in is fix, `:pluginify`, load (§14).
//
// `:plug load <name>` clears it. An explicit load is the author saying they fixed it, and a
// quarantine you cannot lift is a plugin directory you have to edit by hand to get back.

QUARANTINE_FILE :: "quarantine" // beside the binary, next to binds.conf

// Reads what earlier starts left, then hands the handler somewhere to write. Both halves are
// the same file, and the read happens FIRST: the append fd is for the crash that has not
// happened yet.
quarantine_open :: proc(a: ^App) {
    path := quarantine_path(a)
    if path == "" || a.report != nil {
        return
    }
    raw, err := os.read_entire_file(path, context.temp_allocator)
    text := string(raw) if err == nil else ""
    for line in strings.split_lines_iterator(&text) {
        name := strings.trim_space(line)
        if name != "" && !quarantined(a, name) {
            append(&a.quarantined, strings.clone(name))
        }
    }
    f, open_err := os.open(path, {.Write, .Create, .Append}, {.Read_User, .Write_User})
    if open_err == nil {
        a.report = f
        fault_report_fd(os.fd(f))
    }
}

quarantine_destroy :: proc(a: ^App) {
    if a.report != nil {
        fault_report_fd(0)
        os.close(a.report)
        a.report = nil
    }
    for name in a.quarantined {
        delete(name)
    }
    delete(a.quarantined)
    a.quarantined = nil
}

quarantined :: proc(a: ^App, name: string) -> bool {
    return slice.contains(a.quarantined[:], name)
}

// The author says it is fixed. The name leaves the list and the file, so the start after this
// one loads it like any other.
quarantine_clear :: proc(a: ^App, name: string) {
    i, found := slice.linear_search(a.quarantined[:], name)
    if !found {
        return
    }
    delete(a.quarantined[i])
    ordered_remove(&a.quarantined, i)
    path := quarantine_path(a)
    if path == "" {
        return
    }
    if len(a.quarantined) == 0 {
        os.remove(path)
        return
    }
    b := strings.builder_make(context.temp_allocator)
    for left in a.quarantined {
        fmt.sbprintfln(&b, "%s", left)
    }
    _ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

@(private = "file")
quarantine_path :: proc(a: ^App) -> string {
    if a.home == "" {
        return ""
    }
    path, _ := filepath.join({a.home, QUARANTINE_FILE}, context.temp_allocator)
    return path
}

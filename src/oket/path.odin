package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

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

// --- where oket's own files live ---

// One directory per KIND of file, chosen by where the binary is. The split is what you EDIT
// against what a release WROTE against what a crash LEFT, and only the first of those is a file
// anybody opens on purpose.
//
//   Portable   the binary is not in a bin directory: all three are the folder beside it, which
//              is `build/oket` and an unpacked tarball, and is what oket has always done.
//   Installed  the binary IS in one, so the XDG directories hold the files: a bin folder holds
//              programs, not their data.
//
// There is no search path. A mode picks one directory per kind and reads and writes only there.
//
// State is `$XDG_STATE_HOME` and not `$XDG_RUNTIME_DIR`: the runtime directory is wiped at
// logout, and a crash journal that does not outlive a logout is not a crash journal.

Install_Mode :: enum {
    Portable,
    Installed,
}

Home :: struct {
    mode:   Install_Mode,
    config: string, // owned; binds.conf, config.conf
    data:   string, // owned; plugins/, themes/, grammars/, helpers/, notes.md, the tools
    state:  string, // owned; journal/, quarantine, session, the dumps
}

APP_DIR :: "oket" // the folder name inside each XDG root, and what you type

// Not `~/.local/bin` exactly: `/usr/bin`, `/usr/local/bin` and `/opt/x/bin` are bin directories
// too, and a packaged oket that could never be Installed would be a rule serving only the one
// installer we ship. Pure, so the suite can ask about machines this one is not.
home_classify :: proc(exe_dir: string) -> Install_Mode {
    return filepath.base(exe_dir) == "bin" ? .Installed : .Portable
}

// Asked once, at app_init. The mode cannot change while we run, and a live process whose config
// directory moved would move its journal and its plugins out from under itself.
home_resolve :: proc() -> Home {
    dir := exe_dir(context.temp_allocator)
    if home_classify(dir) == .Portable {
        h: Home
        home_set(&h, dir)
        return h
    }
    return home_xdg()
}

// The three XDG directories, whatever mode this process resolved to. `:oket install` is run
// from a Portable build and what it installs is this answer, so the two callers need it apart
// from the mode.
//
// No $HOME and no absolute $XDG_* leaves that one directory empty, and empty is the answer
// every write site already refuses on. Beside the binary is not a fallback: it is the other
// mode.
home_xdg :: proc() -> (h: Home) {
    h.mode = .Installed
    h.config = xdg_join("XDG_CONFIG_HOME", ".config")
    h.data = xdg_join("XDG_DATA_HOME", ".local/share")
    h.state = xdg_join("XDG_STATE_HOME", ".local/state")
    return
}

// All three at one directory, which IS Portable. The test seam too: a suite hands over a temp
// directory and gets the layout every existing test was written against.
home_set :: proc(h: ^Home, dir: string) {
    home_destroy(h)
    h.mode = .Portable
    h.config = strings.clone(dir)
    h.data = strings.clone(dir)
    h.state = strings.clone(dir)
}

home_destroy :: proc(h: ^Home) {
    delete(h.config)
    delete(h.data)
    delete(h.state)
    h^ = {}
}

// The directory the binary is in. `/proc/self/exe` rather than `os.args[0]`, which is the bare
// name when a shell found us on $PATH — and `filepath.dir` of that is ".".
exe_dir :: proc(allocator := context.allocator) -> string {
    path := os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0]
    return strings.clone(filepath.dir(path), allocator) // filepath.dir slices path
}

// The binary itself, for naming it and for copying it. Same source as exe_dir.
exe_path :: proc(allocator := context.allocator) -> string {
    return strings.clone(os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0],
                         allocator)
}

// `$VAR` if it is absolute, else `$HOME/<fallback>`. The XDG rule: a relative value is invalid,
// not relative to something. "" with no $HOME.
xdg_root :: proc(env, fallback: string, allocator := context.allocator) -> string {
    root := os.get_env(env, context.temp_allocator)
    if filepath.is_abs(root) {
        return strings.clone(root, allocator)
    }
    home := os.get_env("HOME", context.temp_allocator)
    if home == "" {
        return strings.clone("", allocator)
    }
    dir, _ := filepath.join({home, fallback}, allocator)
    return dir
}

// The ROOT of it, not oket's folder inside: `applications/` is a shared tree every launcher
// reads, and an entry filed under `oket/` is invisible (desktop.odin).
xdg_data_home :: proc(allocator := context.allocator) -> string {
    return xdg_root("XDG_DATA_HOME", ".local/share", allocator)
}

@(private = "file")
xdg_join :: proc(env, fallback: string) -> string {
    root := xdg_root(env, fallback, context.temp_allocator)
    if root == "" {
        return ""
    }
    dir, _ := filepath.join({root, APP_DIR})
    return dir
}

// The directories, into our own environment, for the two readers that are not Odin code: the
// syntax plugin asks for `$OKET_HOME` to find `grammars/` (plugins/syntax/syntax.c), and
// `oket-grammar` asks for `$OKET_GRAMMARS` and then `$OKET_HOME/grammars` to build one into.
// Both already read these names; nothing has ever set them, because both guessed "beside the
// binary" and both were right until there were three directories to choose between.
//
// This is why the seam does not grow a paths message. The plugin already asks the question and
// already has a channel for the answer, and a seventh message is what the ten rules exist to
// prevent.
//
// `OKET_HOME` is the DATA directory, not the config one: it is the name syntax.c already reads
// and grammars are data.
home_export :: proc() {
    h := home_resolve()
    defer home_destroy(&h)
    if h.data != "" {
        grammars, _ := filepath.join({h.data, "grammars"}, context.temp_allocator)
        _ = os.set_env("OKET_HOME", h.data)
        _ = os.set_env("OKET_DATA", h.data)
        _ = os.set_env("OKET_GRAMMARS", grammars)
    }
    if h.config != "" {
        _ = os.set_env("OKET_CONFIG", h.config)
    }
    if h.state != "" {
        _ = os.set_env("OKET_STATE", h.state)
    }
}

// Can that directory be written? A directory that is not there answers no, which is the right
// answer twice over: an Installed oket has none until `:oket install` makes them, and a
// Portable one unpacked somewhere root owns never will.
home_writable :: proc(dir: string) -> bool {
    if dir == "" {
        return false
    }
    c := strings.clone_to_cstring(dir, context.temp_allocator)
    return linux.access(c, linux.W_OK) == .NONE
}

package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// `:oket status | install | uninstall | update` (INSTALL.md §4), and the `--install` /
// `--uninstall` / `--status` forms install.sh reaches on a machine with no display.
//
// A release is a DIRECTORY, so installing it is a copy of several things and the binary is one
// of them. Leaving it out is what creates the state where the payload is installed and the
// binary is not — Installed nowhere, and Portable in a folder you were about to delete.

// Where an install puts the binary. Any `bin` directory reads as Installed (path.odin), because
// a packaged oket lands in /usr/bin; this is the one a user-level install may WRITE to.
INSTALL_BIN_REL :: ".local/bin"

// What a release put beside the binary, and so what an install carries into the data directory.
// The uninstall does not read this: it removes the three directories whole (install_remove).
//
// `grammars/`, `themes/` and `vendor/` are deliberately absent: no release ships one. An
// install creates the first two empty, and each fills up on the machine that wants it. The
// default theme is in the binary (theme.odin, THEME_BAKED) and tree-sitter is a recipe beside
// the plugin that links it (plugins/syntax/get-tree-sitter).
@(private = "file", rodata)
PAYLOAD := [?]string{"plugins", "helpers", "stage.sh", "oket-grammar", NOTES_NAME}

// Where an install writes: one value, so the two verbs, the status and the suite all name the
// same places. Resolved from the environment ONCE and then passed, because `home_xdg` reads
// $XDG_* and $HOME and the threaded suite cannot set those without racing every other App.
Install_Target :: struct {
    dirs:    Home, // config, data, state
    bin:     string, // owned; "" with no $HOME
    desktop: string, // owned; the launcher entry, "" with no $HOME
    icon:    string, // owned; what the entry's `Icon=oket` resolves to
}

install_target :: proc() -> (t: Install_Target) {
    t.dirs = home_xdg()
    t.desktop = desktop_path()
    t.icon = icon_path()
    // Any `bin` directory reads as Installed (path.odin), because a packaged oket lands in
    // /usr/bin. This is the one a user-level install may WRITE to.
    if home := os.get_env("HOME", context.temp_allocator); home != "" {
        t.bin, _ = filepath.join({home, INSTALL_BIN_REL, APP_DIR})
    }
    return
}

install_target_destroy :: proc(t: ^Install_Target) {
    home_destroy(&t.dirs)
    delete(t.bin)
    delete(t.desktop)
    delete(t.icon)
    t^ = {}
}

// --- install ---

// Idempotent. A rerun replaces the binary and the payload and leaves what is yours — config,
// binds, state, grammars, themes — alone, which makes this the develop loop, and `update`.
// The uninstall is the asymmetric one: it takes those too.
install_run :: proc(a: ^App, t: Install_Target) -> (ok: bool, msg: string) {
    if t.bin == "" || t.dirs.data == "" {
        return false, "install: no $HOME, so there is nowhere to install to"
    }

    b := strings.builder_make(context.temp_allocator)
    grammars, _ := filepath.join({t.dirs.data, "grammars"}, context.temp_allocator)
    themes, _ := filepath.join({t.dirs.data, "themes"}, context.temp_allocator)
    // Created empty rather than on first use, so the folders an install names are folders you
    // can open.
    dirs := [?]string {
        filepath.dir(t.bin), // a slice of t.bin
        t.dirs.config,
        t.dirs.data,
        t.dirs.state,
        grammars,
        themes,
    }
    for dir in dirs {
        if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
            return false, fmt.tprintf("install: cannot create %s (%v)", dir, err)
        }
    }

    exe := exe_path(context.temp_allocator)
    if exe == t.bin {
        fmt.sbprintfln(&b, "  %s is already the installed copy", t.bin)
    } else if err := publish(t.bin, exe); err != nil {
        return false, fmt.tprintf("install: cannot publish %s (%v)", t.bin, err)
    } else {
        fmt.sbprintfln(&b, "  %s -> %s", exe, t.bin)
    }

    // Out of the folder beside the binary, which is a tarball you unpacked or a build you made.
    // Nothing beside an already-installed copy is not an error: install.sh unpacked the payload
    // straight into the data directory and there is nothing left to move.
    from := exe_dir(context.temp_allocator)
    for name in PAYLOAD {
        src, _ := filepath.join({from, name}, context.temp_allocator)
        dst, _ := filepath.join({t.dirs.data, name}, context.temp_allocator)
        if n := copy_tree(dst, src); n > 0 {
            fmt.sbprintfln(&b, "  %s -> %s (%d file%s)", name, dst, n, n == 1 ? "" : "s")
        }
    }

    // The one place config.conf is ever created. Written from the settings table, so what an
    // install lays down and what the kernel reads cannot drift (config.odin). binds.conf is NOT
    // written: its defaults live in the code, and the file holds what a plugin asked for and
    // what you typed (binds.odin).
    cfg, _ := filepath.join({t.dirs.config, CONFIG_NAME}, context.temp_allocator)
    if config_defaults_write(a, cfg) {
        fmt.sbprintfln(&b, "  %s (defaults, from the binary)", cfg)
    }

    if desktop_add(t.desktop, t.bin) {
        fmt.sbprintfln(&b, "  %s", t.desktop)
    }
    if icon_add(t.icon) {
        fmt.sbprintfln(&b, "  %s", t.icon)
    }

    fmt.sbprintfln(&b, "  config:   %s", t.dirs.config)
    fmt.sbprintfln(&b, "  data:     %s", t.dirs.data)
    fmt.sbprintfln(&b, "  state:    %s", t.dirs.state)
    install_path_note(&b, filepath.dir(t.bin))
    if exe != t.bin {
        // The mode was resolved at startup and the copy is at another path, so this process is
        // still the one it was. Nothing here re-points it.
        fmt.sbprintfln(&b, "\n  restart to run the installed copy; %s is yours to delete", from)
    }
    return true, fmt.tprintf("installed\n%s", strings.trim_right_space(strings.to_string(b)))
}

// EVERYTHING, and there is no second command to finish afterwards. It takes the settings you
// wrote, the journals a crash left and the grammars you paid for in wall-clock.
//
// The three directories go WHOLE rather than a row at a time. A table of what an install wrote
// can forget a row; a directory cannot forget what is inside it. Each of the three ends in
// APP_DIR (path.odin), so this never reaches a bare XDG root.
install_remove :: proc(t: Install_Target) -> (ok: bool, msg: string) {
    if t.bin == "" || t.dirs.data == "" {
        return false, "uninstall: no $HOME, so nothing could have been installed"
    }

    b := strings.builder_make(context.temp_allocator)
    gone := 0
    for dir in ([?]string{t.dirs.config, t.dirs.data, t.dirs.state}) {
        if dir != "" && os.exists(dir) && os.remove_all(dir) == nil {
            fmt.sbprintfln(&b, "  removed %s", dir)
            gone += 1
        }
    }
    // Outside the three: a launcher entry and an icon land in the shared XDG folders.
    if desktop_remove(t.desktop) {
        fmt.sbprintfln(&b, "  removed %s", t.desktop)
        gone += 1
    }
    if icon_remove(t.icon) {
        fmt.sbprintfln(&b, "  removed %s", t.icon)
        gone += 1
    }
    if os.exists(t.bin) {
        if err := os.remove(t.bin); err != nil {
            return false, fmt.tprintf("uninstall: cannot remove %s (%v)", t.bin, err)
        }
        fmt.sbprintfln(&b, "  removed %s", t.bin)
        gone += 1
    }
    if gone == 0 {
        return false, "uninstall: nothing of an install is here to remove"
    }
    return true, fmt.tprintf("uninstalled\n%s", strings.trim_right_space(strings.to_string(b)))
}

// --- status ---

// The mode, every path it chose, and any reason nothing below can be saved. Temp-allocated.
install_status :: proc(a: ^App, t: Install_Target) -> string {
    b := strings.builder_make(context.temp_allocator)
    cfg, _ := filepath.join({a.home.config, CONFIG_NAME}, context.temp_allocator)
    fmt.sbprintfln(&b, "mode:      %s", install_mode_label(a.home.mode))
    fmt.sbprintfln(&b, "binary:    %s", exe_path(context.temp_allocator))
    fmt.sbprintfln(&b, "config:    %s%s", a.home.config, os.exists(cfg) ? "" : "   (no config.conf yet)")
    fmt.sbprintfln(&b, "data:      %s", a.home.data)
    fmt.sbprintfln(&b, "state:     %s", a.home.state)
    fmt.sbprintfln(&b, "launcher:  %s",
                   os.exists(t.desktop) ? t.desktop : "not in the application list")
    switch {
    case !home_writable(a.home.config) && a.home.mode == .Installed:
        fmt.sbprintfln(&b, "\n%s is not there, so no setting can be saved.\nMake it: :oket install",
                       a.home.config)
    case !home_writable(a.home.config):
        fmt.sbprintfln(&b, "\n%s cannot be written, so no setting can be saved.\nInstall a copy that can: :oket install",
                       a.home.config)
    }
    install_path_note(&b, filepath.dir(t.bin))
    return strings.trim_right_space(strings.to_string(b))
}

install_mode_label :: proc(m: Install_Mode) -> string {
    switch m {
    case .Portable:  return "portable"
    case .Installed: return "installed"
    }
    return ""
}

// An install a shell cannot reach by name is half of one, and the fix is a line the user runs.
@(private = "file")
install_path_note :: proc(b: ^strings.Builder, dir: string) {
    if dir == "" || dir == "." || on_path(dir) {
        return
    }
    fmt.sbprintfln(b, "\n  %s is not on your PATH. Add it:\n    export PATH=\"%s:$PATH\"", dir, dir)
}

// --- the copying ---

// Staged beside the target and renamed over it. A rename is atomic, and it is the one way to
// replace a binary that may be RUNNING or a plugin that may be MAPPED: writing in place fails
// with ETXTBSY or corrupts the mapping, while a rename leaves the running process on the old
// inode until it exits.
@(private = "file")
publish :: proc(dst, src: string) -> os.Error {
    stage := fmt.tprintf("%s.tmp", dst)
    _ = os.remove(stage) // a stale stage from a run that died
    os.copy_file(stage, src) or_return
    if err := os.rename(stage, dst); err != nil {
        _ = os.remove(stage)
        return err
    }
    return nil
}

// A file or a whole directory, replacing anything already there: the payload is release-owned,
// and skipping would leave release N's plugins under release N+1's binary. Each file goes
// through publish, because the old copy may be a plugin the running process has mapped. Answers
// how many files landed — 0 covers "no source" and a copy that failed. Not file-private: the
// replacement rule is tested (install_test.odin).
copy_tree :: proc(dst, src: string) -> (n: int) {
    if dst == "" || src == "" || dst == src || !os.exists(src) {
        return 0
    }
    if !os.is_dir(src) {
        _ = os.make_directory_all(filepath.dir(dst)) // a slice of dst
        return publish(dst, src) == nil ? 1 : 0
    }
    f, err := os.open(src)
    if err != nil {
        return 0
    }
    defer os.close(f)
    _ = os.make_directory_all(dst)
    it := os.read_directory_iterator_create(f)
    defer os.read_directory_iterator_destroy(&it)
    for info in os.read_directory_iterator(&it) {
        from, _ := filepath.join({src, info.name}, context.temp_allocator)
        to, _ := filepath.join({dst, info.name}, context.temp_allocator)
        n += copy_tree(to, from)
    }
    return
}

// An exact match: a prefix test would call ~/.local/binaries a hit.
@(private = "file")
on_path :: proc(dir: string) -> bool {
    rest := os.get_env("PATH", context.temp_allocator)
    for entry in strings.split_iterator(&rest, ":") {
        if entry == dir {
            return true
        }
    }
    return false
}

// --- the two doors ---

USAGE_OKET :: ":oket status | install | uninstall | update"

// Fetch plus the install above, done where the user can watch: install.sh in N0, which
// downloads the release and runs the new binary's `--install`. The kernel gets no HTTP client.
UPDATE_LINE :: "curl -fsSL https://github.com/ItsNotPaths/oket/releases/latest/download/install.sh | sh"

builtin_oket :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    t := install_target()
    defer install_target_destroy(&t)
    ok: bool
    msg: string
    switch strings.trim_space(args) {
    case "", "status":
        sys_println(a, install_status(a, t))
        return true
    case "update":
        // install.sh installs, so a portable copy would come out Installed without being asked.
        if a.home.mode == .Portable {
            message_set(a, "update: this copy is portable; unpack the new tarball over it, or :oket install first")
            return false
        }
        cl_exec(a, UPDATE_LINE)
        return true
    case "install":
        ok, msg = install_run(a, t)
    case "uninstall":
        ok, msg = install_remove(t)
    case:
        message_set(a, USAGE_OKET)
        return false
    }
    sys_println(a, msg)
    if !ok {
        message_set(a, msg)
    }
    // The directories moved under us, and what reads them next should read the new ones.
    home_refresh(a)
    return ok
}

// Before the window opens, because install.sh runs these on a machine with no display and the
// same code has to answer there.
install_cli :: proc(a: ^App, args: []string) -> (handled: bool) {
    t := install_target()
    defer install_target_destroy(&t)
    for arg in args {
        switch arg {
        case "--status":
            fmt.println(install_status(a, t))
        case "--install":
            _, msg := install_run(a, t)
            fmt.println(msg)
        case "--uninstall":
            _, msg := install_remove(t)
            fmt.println(msg)
        case:
            continue
        }
        return true
    }
    return false
}

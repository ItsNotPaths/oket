package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../desc"
import "../store"
import app "../oket"

// `:oket install` and `:oket uninstall` (INSTALL.md §4, §5). The destination is an argument
// rather than read out of $XDG_*, so these point one at a scratch tree and never touch the
// environment the rest of the threaded suite is running in.

@(private = "file")
target_at :: proc(root: string) -> (t: app.Install_Target) {
    config, _ := filepath.join({root, "config"})
    data, _ := filepath.join({root, "data"})
    state, _ := filepath.join({root, "state"})
    t.dirs = {mode = .Installed, config = config, data = data, state = state}
    t.bin, _ = filepath.join({root, "bin", "oket"})
    t.desktop, _ = filepath.join({root, "applications", "oket.desktop"})
    t.icon, _ = filepath.join({root, "icons", "oket.svg"})
    return
}

@(private = "file")
there :: proc(parts: ..string) -> bool {
    path, _ := filepath.join(parts, context.temp_allocator)
    return os.exists(path)
}

// The three directories, `grammars/` empty beside them, and the one place config.conf is ever
// created. The binary lands too: leaving it out is what makes a payload installed and a binary
// not (§4).
@(test)
an_install_lays_down_every_directory :: proc(t: ^testing.T) {
    root, ok := scratch(t, "oket-install-run")
    if !ok {
        return
    }
    a, made := bare_app()
    if !testing.expect(t, made, "no App") {
        return
    }
    defer close_app(&a)
    tgt := target_at(root)
    defer app.install_target_destroy(&tgt)

    ran, msg := app.install_run(&a, tgt)
    if !testing.expect(t, ran, msg) {
        return
    }
    testing.expect(t, there(root, "config", app.CONFIG_NAME), "no config.conf")
    testing.expect(t, there(root, "data", "grammars"), "no grammars directory")
    testing.expect(t, there(root, "state"), "no state directory")
    testing.expect(t, os.exists(tgt.bin), "the binary was not installed")
    testing.expect(t, os.exists(tgt.desktop), "no launcher entry")
    testing.expect(t, os.exists(tgt.icon), "no icon")
    // binds.conf is not written: its defaults live in the code, and the file holds what a plugin
    // asked for and what you typed.
    testing.expect(t, !there(root, "config", "binds.conf"), "an install wrote binds.conf")
}

// A rerun after a rebuild replaces the binary and leaves every file it already wrote alone,
// which is what makes this the develop loop as well as the install.
@(test)
a_second_install_overwrites_nothing :: proc(t: ^testing.T) {
    root, ok := scratch(t, "oket-install-twice")
    if !ok {
        return
    }
    a, made := bare_app()
    if !testing.expect(t, made, "no App") {
        return
    }
    defer close_app(&a)
    tgt := target_at(root)
    defer app.install_target_destroy(&tgt)
    if ran, msg := app.install_run(&a, tgt); !testing.expect(t, ran, msg) {
        return
    }

    cfg, _ := filepath.join({root, "config", app.CONFIG_NAME}, context.temp_allocator)
    mine := "\n[strip] gap = 11\n"
    raw, _ := os.read_entire_file(cfg, context.temp_allocator)
    edited := strings.concatenate({string(raw), mine}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(cfg, transmute([]u8)edited), nil)

    if ran, msg := app.install_run(&a, tgt); !testing.expect(t, ran, msg) {
        return
    }
    after, err := os.read_entire_file(cfg, context.temp_allocator)
    testing.expect_value(t, err, nil)
    testing.expect(t, strings.contains(string(after), mine), "a rerun rolled the settings back")
}

// Exactly the list an install writes, and nothing else: the crash you are recovering from may be
// why you are uninstalling, and a grammar is a build somebody paid for in wall-clock.
@(test)
an_uninstall_keeps_settings_state_and_grammars :: proc(t: ^testing.T) {
    root, ok := scratch(t, "oket-install-remove")
    if !ok {
        return
    }
    a, made := bare_app()
    if !testing.expect(t, made, "no App") {
        return
    }
    defer close_app(&a)
    tgt := target_at(root)
    defer app.install_target_destroy(&tgt)
    if ran, msg := app.install_run(&a, tgt); !testing.expect(t, ran, msg) {
        return
    }

    built, _ := filepath.join({root, "data", "grammars", "json.so"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(built, transmute([]u8)string("x")), nil)
    work, _ := filepath.join({root, "state", "journal"}, context.temp_allocator)
    testing.expect_value(t, os.make_directory_all(work), nil)

    gone, msg := app.install_remove(tgt)
    if !testing.expect(t, gone, msg) {
        return
    }
    testing.expect(t, !os.exists(tgt.bin), "the binary survived")
    testing.expect(t, !os.exists(tgt.desktop), "the launcher entry survived")
    testing.expect(t, !os.exists(tgt.icon), "the icon survived")
    testing.expect(t, !there(root, "data", "plugins"), "plugins/ survived")
    testing.expect(t, os.exists(built), "a grammar was taken")
    testing.expect(t, os.exists(work), "the state directory was taken")
    testing.expect(t, there(root, "config", app.CONFIG_NAME), "config.conf was taken")
}

// Nothing there is a refusal with a reason, not a success that removed nothing.
@(test)
uninstalling_nothing_says_so :: proc(t: ^testing.T) {
    root, ok := scratch(t, "oket-install-empty")
    if !ok {
        return
    }
    tgt := target_at(root)
    defer app.install_target_destroy(&tgt)
    gone, msg := app.install_remove(tgt)
    testing.expect(t, !gone, "an empty uninstall reported success")
    testing.expect(t, strings.contains(msg, "nothing"), msg)
}

// No $HOME leaves every path empty, and a write to "" is the one thing neither verb may try.
@(test)
neither_verb_writes_without_a_target :: proc(t: ^testing.T) {
    a, made := bare_app()
    if !testing.expect(t, made, "no App") {
        return
    }
    defer close_app(&a)
    ran, _ := app.install_run(&a, app.Install_Target{})
    testing.expect(t, !ran, "an install with nowhere to go reported success")
    gone, _ := app.install_remove(app.Install_Target{})
    testing.expect(t, !gone, "an uninstall with nowhere to look reported success")
}

// A desktop entry is launched with the session's PATH, and ~/.local/bin is not always on it — so
// both command lines carry the absolute path, and `%F` survives the rewrite. Pure, so this needs
// no $HOME and no launcher.
@(test)
the_entry_names_the_binary_and_keeps_its_field_code :: proc(t: ^testing.T) {
    src := "[Desktop Entry]\nName=Oket\nExec=oket %F\nTryExec=oket\nMimeType=text/plain;\n"
    out := app.desktop_text(src, "/opt/x/bin/oket", context.temp_allocator)
    testing.expect(t, strings.contains(out, "Exec=/opt/x/bin/oket %F"), out)
    testing.expect(t, strings.contains(out, "TryExec=/opt/x/bin/oket\n"), out)
    testing.expect(t, strings.contains(out, "MimeType=text/plain;"), "a line that is not a command was rewritten")
    testing.expect(t, !strings.contains(out, "Exec=oket"), "the bare name survived")
}

// The template that SHIPS is the one the rewrite is checked against: a `%F` dropped from the
// file would leave every association silently opening nothing.
@(test)
the_shipped_template_opens_what_a_launcher_hands_it :: proc(t: ^testing.T) {
    out := app.desktop_text(app.DESKTOP_SRC, "/usr/bin/oket", context.temp_allocator)
    testing.expect(t, strings.contains(out, "Exec=/usr/bin/oket %F"), out)
    testing.expect(t, strings.contains(out, "StartupWMClass=oket"), "nothing ties a window to the entry")
    // A NAME, so a launcher resolves it through the icon theme and a theme can override it.
    testing.expect(t, strings.contains(out, "\nIcon=oket\n"), "the entry names no icon")
}

// What an install writes as the icon is the drawing in the repo, and it has to be an SVG a
// launcher will parse — an empty or truncated #load would file a broken icon silently.
@(test)
the_icon_is_the_drawing_in_the_repo :: proc(t: ^testing.T) {
    testing.expect(t, strings.contains(app.DESKTOP_ICON_SRC, "<svg"), "the icon is not an SVG")
    testing.expect(t, strings.contains(app.DESKTOP_ICON_SRC, "</svg>"), "the icon is truncated")
}

// --- the command line's own arguments (INSTALL.md §6) ---

// A leading `-` is the only test, so `oket -x` is a flag and `oket ./-x` is a file. Every other
// program on the machine draws the line there.
@(test)
a_flag_is_not_a_path :: proc(t: ^testing.T) {
    got := app.args_paths({"--safe", "note.txt", "-q", "", "src", "./-x"}, context.temp_allocator)
    testing.expect_value(t, len(got), 3)
    testing.expect_value(t, got[0], "note.txt")
    testing.expect_value(t, got[1], "src")
    testing.expect_value(t, got[2], "./-x")
}

// The FIRST directory named, absolute — a terminal spawned in a relative path would land
// somewhere else the moment a shell step moved the working directory.
@(test)
the_first_directory_is_where_this_start_is :: proc(t: ^testing.T) {
    dir, ok := scratch(t, "oket-args-dir")
    if !ok {
        return
    }
    note, _ := filepath.join({dir, "alpha.txt"}, context.temp_allocator)
    got := app.start_dir({note, dir}, context.temp_allocator)
    testing.expect_value(t, got, dir)
    testing.expect(t, filepath.is_abs(got), got)
}

// No directory among them leaves the working directory this start was launched from, which is
// what the home page names and what every terminal is spawned in.
@(test)
no_directory_leaves_the_working_one :: proc(t: ^testing.T) {
    cwd, _ := os.get_working_directory(context.temp_allocator)
    got := app.start_dir({"--safe", "no-such-file.txt"}, context.temp_allocator)
    testing.expect_value(t, got, cwd)
}

// An argument beats the session and beats the home page: this start was TOLD where to go. The
// editor plugin is loaded because the kernel opens no file on its own (§7) — an argument reaches
// `:open` and stops exactly where a typed line would.
@(test)
an_argument_opens_instead_of_the_page :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-args-open", "plugins/edit")
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    app.plug_autoload(&a)

    note, _ := filepath.join({home_dir(a.home), "alpha.txt"}, context.temp_allocator)
    testing.expect(t, app.args_open(&a, {note}), a.message)
    s := app.ring_focused(&a)
    if !testing.expect(t, s != nil, "nothing was opened") {
        return
    }
    d := store.store_descriptor(&a.docs, s.doc)
    defer desc.release(d)
    testing.expect_value(t, d.file, note)
}

// Nothing to open is what leaves the home page standing, and the ring untouched.
@(test)
no_argument_opens_nothing :: proc(t: ^testing.T) {
    a, made := bare_app()
    if !testing.expect(t, made, "no App") {
        return
    }
    defer close_app(&a)
    testing.expect(t, !app.args_open(&a, {"--safe"}), "a flag was opened as a path")
    testing.expect(t, app.ring_focused(&a) == nil, "something landed in the ring")
}

// --- a directory that cannot be written (INSTALL.md §2) ---

// r-xr-xr-x and rwxr-xr-x. Spelled as flags because os.Permissions is a bit_set, so the octal a
// person would type is not a value it takes.
@(private = "file")
READ_ONLY :: os.Permissions{.Read_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}
@(private = "file")
WRITABLE :: READ_ONLY + {.Write_User}

// Read-only is a PROPERTY, not a mode: the mode says where the files are and this says whether
// they can be written. A start over a folder root owns reads what is there and writes nothing.
@(test)
a_start_that_cannot_write_writes_nothing :: proc(t: ^testing.T) {
    dir, ok := scratch(t, "oket-readonly")
    if !ok {
        return
    }
    if err := os.chmod(dir, READ_ONLY); err != nil {
        testing.expectf(t, false, "cannot chmod %s: %v", dir, err)
        return
    }
    defer os.chmod(dir, WRITABLE) // or the runner cannot clean up after itself
    testing.expect(t, !app.home_writable(dir), "a read-only directory reported writable")

    a, made := bare_app()
    if !testing.expect(t, made, "no App") {
        return
    }
    defer close_app(&a)
    app.home_set(&a.home, dir)
    app.config_sync(&a)
    app.binds_sync(&a)
    testing.expect(t, !there(dir, app.CONFIG_NAME), "config.conf was written anyway")
    testing.expect(t, !there(dir, "binds.conf"), "binds.conf was written anyway")
    // The defaults still stand: what is refused is the WRITE, not the settings.
    testing.expect_value(t, a.config.gap, app.config_default().gap)
    // And the page says why, which is the whole point of refusing loudly.
    page := app.home_open(&a)
    app.ring_add(&a, page)
    testing.expect(t, strings.contains(doc_text(&a, page), ":oket install"),
                   "the page did not say why nothing can be saved")
}

package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import "../gfx"
import "../input"

// The harness (AUTHORING.md §6): a second oket with the fault net disarmed, driven by a file
// instead of by a window.
//
// THAT ONE DIFFERENCE IS THE POINT. In the live editor recovery is correct and diagnosis is the
// casualty — a plugin that faults is unwound and named, and the core file is written exactly
// when recovery FAILED. Here there is nothing to keep running for, so no handler is installed,
// a fault drops a core, and gdb has a corpse.
//
// Not a second binary. `main` branches before the window comes up and everything below this
// line is the App every other file already talks to, which is why there is no second plugin
// loader and no second settle loop to keep in step.
//
// A sequence file is four line shapes and no parser, because oket has a command language
// already: `:` is a chain line, `>` is a chord, `!` is an assertion, `#` is a comment, and
// anything else is text typed into the focused document.
//
// `!` IS THE ONLY JUDGE. A chain line that fails is not a failed step: `||` exists, and a repro
// whose point is that `:open` refuses would have no way to say so. What a step did is asked
// about afterwards, in the one vocabulary `:get` answers in.

HARNESS :: "--harness"
HARNESS_DUMP :: "--dump"
USAGE_HARNESS_CLI :: "usage: oket --harness [--dump] <sequence> [<plugin>...]"

// A screen, because a panel with no rectangle draws nothing and a motion over it measures
// nothing. Eighty by twenty-four is a terminal's, and a sequence that cares says `:width`.
HARNESS_COLS :: 80
HARNESS_ROWS :: 24

// How long a step may take before the run gives up on it, and the poll between two passes of
// the pumps. The same shape the suite's `io_settle` has, and for the same reason: there is no
// window to be woken by, so a completion is waited for rather than delivered.
HARNESS_WAIT :: 5 * time.Second
HARNESS_TICK :: 5 * time.Millisecond
HARNESS_TICKS :: int(HARNESS_WAIT / HARNESS_TICK)

// `oket --harness <sequence> [<plugin>...]`. Answers the process's exit code: 0 is a pass, 1 is
// a failed step, 2 is a run that never got as far as the file.
harness_main :: proc(args: []string) -> int {
    paths := args_paths(args, context.temp_allocator)
    if len(paths) == 0 {
        fmt.eprintln(USAGE_HARNESS_CLI)
        return 2
    }
    // The keymap, which comes up with the video subsystem and not with a window: without it a
    // chord spelled as a layout glyph resolves to nothing, and so does half of binds.conf.
    if !sdl.Init({.VIDEO}) {
        fmt.eprintfln("%s: no display (%s), so only labels and @positions spell a chord",
                      HARNESS, sdl.GetError())
    }
    defer sdl.Quit()

    // A home of its own, thrown away at the end. A repro must not write the config file, the
    // session or the journal of the oket that spawned it, and a run that reads nobody's
    // binds.conf is one another machine reproduces.
    // NOT the temp allocator: a step ends in a `free_all` and this has to outlive every one of
    // them — the path the defer below removes.
    dir, err := os.make_directory_temp("", "oket-harness-*", context.allocator)
    if err != nil {
        fmt.eprintfln("%s: cannot make a scratch home: %v", HARNESS, err)
        return 2
    }
    defer delete(dir)
    defer os.remove_all(dir)

    a: App
    a.harness = true
    home_export() // the REAL directories: a plugin reads them out of the environment (path.odin)
    input_init(&a) // before app_init, because binds.conf spells chords in layout glyphs
    home: Home
    home_set(&home, dir)
    app_init(&a, home)
    defer app_destroy(&a)
    // Not `start_dir`'s answer, which app_init already took: a plugin argument IS a directory,
    // and it would become the place every shell step in the sequence ran in.
    delete(a.dir)
    a.dir, _ = os.get_working_directory(context.allocator)
    gfx.grid_init(&a.chrome, HARNESS_COLS, HARNESS_ROWS)
    surface_fit(&a, HARNESS_COLS, HARNESS_ROWS)

    for plugin in paths[1:] {
        if !harness_plug(&a, plugin) {
            return 2
        }
    }
    return harness_script(&a, paths[0], flag(HARNESS_DUMP)) == 0 ? 0 : 1
}

// A plugin argument is a SOURCE DIRECTORY, built into the scratch home by the one script
// `:pluginify` and release.sh already run, or the NAME of one already installed, loaded out of
// the real data directory. Both end as a path handed to `plug_load`, which is what keeps the
// second case two lines rather than a second loader.
//
// Nothing autoloads. A repro names what it loads, so the bug is yours and not the four plugins
// that happened to be installed on the machine it was written on.
@(private = "file")
harness_plug :: proc(a: ^App, arg: string) -> bool {
    real := home_resolve()
    defer home_destroy(&real)
    if !os.is_dir(arg) {
        so, _ := filepath.join({real.data, PLUGIN_DIR, arg, fmt.tprintf("%s.so", arg)},
                               context.temp_allocator)
        if !os.exists(so) {
            fmt.eprintfln("%s: %s is neither a plugin directory nor an installed plugin",
                          HARNESS, arg)
            return false
        }
        return harness_loaded(a, plug_load(a, so))
    }
    script, _ := filepath.join({real.data, PLUGINIFY_SCRIPT}, context.temp_allocator)
    out, _ := filepath.join({a.home.data, PLUGIN_DIR}, context.temp_allocator)
    state, outs, errs, err := os.process_exec({command = {script, arg, out}},
                                              context.temp_allocator)
    if err != nil || !state.success {
        fmt.eprintfln("%s: cannot build %s: %v\n%s%s", HARNESS, arg, err, string(outs),
                      string(errs))
        return false
    }
    abs, _ := filepath.abs(arg, context.temp_allocator)
    return harness_loaded(a, plug_load(a, plug_path(a, filepath.base(abs))))
}

@(private = "file")
harness_loaded :: proc(a: ^App, ok: bool) -> bool {
    if !ok {
        fmt.eprintfln("%s: %s", HARNESS, a.message)
    }
    return ok
}

// The file, one line one step, echoed as it runs so the run itself is the transcript. Answers
// how many steps failed, and each failure names the sequence file and the line — a `file:line`
// row, which is what N0 already opens on `enter`.
//
// Split from `harness_main` so the suite can drive a sequence against an App it built itself,
// the way `cl_parse` is split from `cl_exec`. The TRANSCRIPT is what `a.harness` gates: a
// process spawned to run one file is all transcript, and a test driving this among others is a
// thread writing into a shared stdout. A failure is printed either way — it is the answer.
harness_script :: proc(a: ^App, path: string, dump := false) -> (failed: int) {
    // NOT the temp allocator: every step ends in a `free_all`, and the file is what the steps
    // are slices of.
    raw, err := os.read_entire_file(path, context.allocator)
    if err != nil {
        fmt.eprintfln("%s: cannot read %s: %v", HARNESS, path, err)
        return 1
    }
    defer delete(raw)

    rest, line := string(raw), 0
    for step in strings.split_lines_iterator(&rest) {
        line += 1
        head := strings.trim_left_space(strings.trim_right(step, "\r"))
        if head == "" || head[0] == '#' {
            continue
        }
        if a.harness {
            fmt.println(head)
        }
        if why := harness_step(a, step, head); why != "" {
            fmt.printfln("%s:%d: %s", path, line, why)
            failed += 1
        }
        if dump {
            harness_dump(a)
        }
        free_all(context.temp_allocator) // the frame's own free, once a step and not once a frame
    }
    if a.harness {
        fmt.printfln("%s: %s", path, failed == 0 ? "ok" : fmt.tprintf("%d failed", failed))
    }
    return
}

// One step. `raw` is the line as written and `head` is it with the left margin off: a text line
// types VERBATIM, because leading whitespace is text, and the sigil is read past it.
@(private = "file")
harness_step :: proc(a: ^App, raw, head: string) -> (why: string) {
    switch head[0] {
    case ':':
        cl_exec(a, head)
    case '>':
        text := strings.trim_space(head[1:])
        // The same parse binds.conf gets, so a chord in a repro is spelled the way the row that
        // fired it is — a primer and its child included (§4.1).
        prefix, chord, parsed := input.chord_pair_parse(text, key_layout_code)
        if !parsed {
            return fmt.tprintf("%s is not a chord", text)
        }
        if prefix != (input.Chord{}) {
            handle_chord(a, prefix)
        }
        handle_chord(a, chord)
    case '!':
        return harness_assert(a, strings.trim_space(head[1:]))
    case:
        // Text is not keys (§8), and it arrives here the way SDL delivers it: one rune at a
        // time, on its own channel. A newline is `> enter`, because that is a chord.
        for r in raw {
            text_input(a, r)
        }
    }
    harness_settle(a)
    return ""
}

// `<what> ==|!=|~|!~ <value>`, where `<what>` is a `:get` name. THE QUERY LANGUAGE IS THE
// ASSERTION LANGUAGE and neither grows alone: both read `get_value`, so a name added for one
// is answerable by the other.
//
// It is also the WAIT. A repro over a plugin that answers on an I/O completion has nothing to
// sleep on, so the check is re-asked while the pumps run rather than made once against a frame
// that has not happened yet. That is the suite's `io_settle`, and it is why there is no fifth
// line shape.
@(private = "file")
harness_assert :: proc(a: ^App, expr: string) -> (why: string) {
    what := first_field(expr)
    rest := strings.trim_space(expr[len(what):])
    op := first_field(rest)
    if what == "" || !harness_op(op) {
        return fmt.tprintf("%s is not `<what> ==|!=|~|!~ <value>`", expr)
    }
    // Trimmed on BOTH sides of the compare, and `got` is trimmed below: a value that ends in a
    // newline is what nearly every `:get` answers, and an assertion nobody can write without
    // counting them is one nobody writes.
    want := strings.trim_space(harness_unescape(strings.trim_space(rest[len(op):])))
    got: string
    for _ in 0 ..< HARNESS_TICKS {
        value, known := get_value(a, what)
        if !known {
            return fmt.tprintf("%s: %s", what, USAGE_GET)
        }
        got = strings.trim_space(value)
        if harness_holds(op, got, want) {
            return ""
        }
        harness_frame(a)
        time.sleep(HARNESS_TICK)
    }
    // Both sides quoted, and for the same reason `want` reads escapes: a value with a newline
    // in it would otherwise break the `file:line:` row this is printed on.
    return fmt.tprintf("%s %s %q, and it is %q", what, op, want, got)
}

// A wanted value is one LINE of the sequence file and a document is not, so the escapes `%q`
// prints come back off here. That closes the loop: what a failure reports is what you paste in
// to make it pass.
@(private = "file")
harness_unescape :: proc(s: string) -> string {
    if !strings.contains(s, "\\") {
        return s
    }
    b := strings.builder_make(context.temp_allocator)
    for i := 0; i < len(s); i += 1 {
        if s[i] != '\\' || i + 1 >= len(s) {
            strings.write_byte(&b, s[i])
            continue
        }
        i += 1
        switch s[i] {
        case 'n':
            strings.write_byte(&b, '\n')
        case 't':
            strings.write_byte(&b, '\t')
        case 'r':
            strings.write_byte(&b, '\r')
        case:
            strings.write_byte(&b, s[i]) // `\\` and `\"`, and anything else is itself
        }
    }
    return strings.to_string(b)
}

@(private = "file")
harness_op :: proc(op: string) -> bool {
    return op == "==" || op == "!=" || op == "~" || op == "!~"
}

@(private = "file")
harness_holds :: proc(op, got, want: string) -> bool {
    switch op {
    case "==":
        return got == want
    case "!=":
        return got != want
    case "~":
        return strings.contains(got, want)
    }
    return !strings.contains(got, want)
}

// One pass of everything main.odin pumps, in main.odin's order, answering whether anything is
// still outstanding. The draw is not decoration: a click, a motion and a row all count from the
// rectangle the last draw laid out.
@(private = "file")
harness_frame :: proc(a: ^App) -> (busy: bool) {
    term_pump(a)
    sh_pump(a)
    chain_pump(a)
    settled := docs_settle(a)
    io_pump(a)
    latched := plug_pump(a) | settled
    surface_draw(a)
    return chain_busy(a) || latched
}

// Until nothing is outstanding, or until the cap. Past the cap the step is abandoned and the
// one after it runs anyway: a hang is not a verdict, and `!` is what turns one into a failure.
@(private = "file")
harness_settle :: proc(a: ^App) {
    for _ in 0 ..< HARNESS_TICKS {
        if !harness_frame(a) {
            return
        }
        time.sleep(HARNESS_TICK)
    }
}

// What no other tool shows: the focused document's bytes, its descriptor, and the span store BY
// PUBLISHER — which is where a syntax plugin's bug lives, because the merged answer the
// renderer reads has already lost whose run was whose.
@(private = "file")
harness_dump :: proc(a: ^App) {
    for what in ([?]string{"text", "desc", "spans"}) {
        value, _ := get_value(a, what)
        fmt.printf("--- %s ---\n%s", what, value)
        if !strings.has_suffix(value, "\n") {
            fmt.println()
        }
    }
}

package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "../desc"
import "../gfx"
import "../input"
import "../pty"
import "../store"
import "../txt"
import "../view"
import app "../oket"

// The gate for build order stage 6: a session is a DOCUMENT. Scrollback and the live grid are
// its lines, the kernel's viewport is what scrolls it, `follow: tail` is the live bottom, and
// colour arrives as style runs — none of it terminal-only code, which is the stage's point.

// Plain /bin/sh for every test shell: the suite spawns several at once, and interactive shells
// sourcing the user's rc are the one flaky-hang source. sh reads no rc at all.
@(init)
test_shell_is_sh :: proc "contextless" () {
    posix.setenv("SHELL", "/bin/sh", true)
}

// How long a test waits on a real shell, which answers on its own clock. Generous on purpose:
// the suite runs 32-way.
TERM_WAIT_STEP :: 5 * time.Millisecond
TERM_WAIT_TRIES :: 4000 // 20s

// A kernel with one session focused, and nothing else in the ring.
@(private = "file")
term_app :: proc(t: ^testing.T, cols := 50, rows := 5) -> (a: app.App, tm: ^app.Term, ok: bool) {
    a = bare_app(cols, rows) or_return
    id, made := app.term_open(&a)
    if !testing.expect(t, made, "no shell to spawn") {
        close_app(&a)
        return {}, nil, false
    }
    app.ring_add(&a, id)
    return a, app.term_of(&a, id), true
}

// The session's document, as the renderer would read it.
@(private = "file")
term_text :: proc(a: ^app.App, tm: ^app.Term) -> string {
    doc := store.store_doc(&a.docs, tm.doc)
    return doc == nil ? "" : txt.doc_string(doc, context.temp_allocator)
}

// Prompts seen so far. sh's prompt ends in "$ ", and a new one means the shell is back at
// read — the only settle signal it gives after spawn or an interrupt.
@(private = "file")
term_prompts :: proc(a: ^app.App, tm: ^app.Term) -> int {
    return strings.count(term_text(a, tm), "$ ")
}

// Pump until the shell prints a prompt past `over`.
@(private = "file")
term_wait_prompts :: proc(t: ^testing.T, a: ^app.App, tm: ^app.Term, over: int) -> bool {
    for _ in 0 ..< TERM_WAIT_TRIES {
        app.term_pump(a)
        store.store_drain(&a.docs)
        if term_prompts(a, tm) > over {
            return true
        }
        time.sleep(TERM_WAIT_STEP)
    }
    testing.expectf(t, false, "the shell never came back to a prompt past %d; alive=%v text=%q",
                    over, pty.terminal_alive(&tm.t), term_text(a, tm))
    return false
}

// Pump until `want` shows up in the document. Real shells answer on their own clock.
@(private = "file")
term_wait_for :: proc(t: ^testing.T, a: ^app.App, tm: ^app.Term, want: string) -> bool {
    for _ in 0 ..< TERM_WAIT_TRIES {
        app.term_pump(a)
        store.store_drain(&a.docs)
        if strings.contains(term_text(a, tm), want) {
            return true
        }
        time.sleep(TERM_WAIT_STEP)
    }
    testing.expectf(t, false, "%q never appeared in the session; text=%q", want, term_text(a, tm))
    return false
}

// Bytes into the VT as if the shell had written them, then one pump. The shell's own output is
// on its own rows, so a marker line is the test's and nothing else writes to it.
@(private = "file")
term_show :: proc(a: ^app.App, tm: ^app.Term, bytes: string) {
    pty.terminal_feed(&tm.t, transmute([]u8)bytes)
    app.term_pump(a)
    store.store_drain(&a.docs)
}

// The document line holding `want`, and -1 for none.
@(private = "file")
term_line_of :: proc(a: ^app.App, tm: ^app.Term, want: string) -> int {
    doc := store.store_doc(&a.docs, tm.doc)
    for line in 0 ..< txt.doc_line_count(doc) {
        if strings.contains(string(txt.doc_line(doc, line)), want) {
            return line
        }
    }
    return -1
}

// The whole of what a terminal is now: text plus a descriptor, which is what makes the kernel
// able to render and route it without one branch that names it.
@(test)
a_session_is_a_document :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    testing.expect(t, pty.terminal_alive(&tm.t))
    testing.expect_value(t, app.kind_name(&a, app.doc_kind(&a, tm.doc)), "term")

    d := store.store_descriptor(&a.docs, tm.doc)
    defer desc.release(d)
    testing.expect_value(t, d.render, desc.Render.Grid)
    testing.expect_value(t, d.follow, desc.Follow.Tail)
    testing.expect_value(t, d.input, desc.Input.Raw)
    testing.expect_value(t, d.ctx, input.Bind_Ctx.Terminal)
    testing.expect(t, !d.editable, "typing reaches the shell, not the piece table")

    // The live grid is the document's lines, and the caret is the shell's cursor.
    term_show(&a, tm, "\r\ngate-6-doc")
    testing.expect(t, term_line_of(&a, tm, "gate-6-doc") >= 0, term_text(&a, tm))
    row, col := pty.terminal_cursor(&tm.t)
    p := app.active(&a).view.point.head
    testing.expect_value(t, p.line, tm.t.sb_total - tm.base + row)
    testing.expect_value(t, p.col, col)
}

// The miss rule (§8): a chord no row claims falls through to the document's own job, because
// the descriptor says `input: raw`. The printf format keeps the marker out of the echoed
// command line, so a match proves execution and not echo.
@(test)
the_miss_rule_sends_keys_to_the_shell :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    for r in `printf 'gate-%s\n' 'send-ok'` {
        app.text_input(&a, r)
    }
    app.handle_chord(&a, chord("RTRN"))
    term_wait_for(t, &a, tm, "gate-send-ok")

    // And the bound `terminal esc` row goes to the job, never to the global quit: Escape has to
    // reach vim inside the shell.
    app.handle_chord(&a, chord("ESC"))
    testing.expect(t, !a.quit, "esc in a session must go to the job")
}

// ctrl+c copies here like everywhere else, and ctrl+shift+c sends what a shell reads as
// SIGINT. This gates the BYTE — that a control character abandons the line rather than
// running it.
//
// It stops at `terminal_input_ctrl` on purpose. The chord's own step is `term_send`, which asks
// GLFW what the key TYPES under the live layout, and a test has no window for GLFW to answer
// from. Which chord arrives here is bind_test's `the_terminal_keeps_the_chords_editing_took`.
@(test)
a_control_byte_abandons_the_line :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    // The interrupt only lands once the line editor holds the whole line: a ^C that beats the
    // shell to the queued bytes is a tty flush of HALF the line instead, and enter then feeds
    // the shell an open quote. So wait for the prompt, then for the echo, and after the ^C for
    // the fresh prompt that is the abandon, seen.
    if !term_wait_prompts(t, &a, tm, 0) {
        return
    }
    for r in `printf 'gate-%s\n' 'abandoned'` {
        app.text_input(&a, r)
    }
    if !term_wait_for(t, &a, tm, "'abandoned'") {
        return
    }
    at := term_prompts(&a, tm)
    pty.terminal_input_ctrl(&tm.t, 'c') // what ctrl+shift+c encodes to
    term_wait_prompts(t, &a, tm, at)
    app.handle_chord(&a, chord("RTRN")) // runs the line, if it somehow survived

    for r in `printf 'gate-%s\n' 'after'` {
        app.text_input(&a, r)
    }
    app.handle_chord(&a, chord("RTRN"))
    term_wait_for(t, &a, tm, "gate-after")

    // The printf format keeps the marker out of the echoed line, so its absence means the
    // command never ran rather than that it was never typed.
    testing.expect(t, !strings.contains(term_text(&a, tm), "gate-abandoned"),
                   "a control byte did not interrupt the line")
}

// Scrollback is document lines, so the KERNEL's viewport scrolls it and there is no terminal
// scroll verb to bind. `follow: tail` rides the bottom, scrolling up parks you, and scrolling
// back picks the bottom up again — no attached flag, so nothing can disagree with the screen.
@(test)
the_kernel_viewport_scrolls_a_session :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t, 40, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    for _ in 0 ..< 40 {
        term_show(&a, tm, "line\r\n")
    }
    s := app.ring_focused(&a)
    doc := store.store_doc(&a.docs, tm.doc)
    bottom := max(txt.doc_line_count(doc) - app.panel_focused(&a).body.h, 0)
    testing.expect_value(t, s.view.top, bottom)
    testing.expect(t, tm.t.sb_total > 0, "nothing scrolled off into history")

    // Shift+PgUp is view.page_up, the same verb every document has.
    app.handle_chord(&a, chord("PGUP", {.Shift}))
    parked := s.view.top
    testing.expect(t, parked < bottom, "a page up went nowhere")

    term_show(&a, tm, "more\r\n")
    testing.expect_value(t, s.view.top, parked) // parked stays parked

    app.handle_chord(&a, chord("PGDN", {.Shift}))
    app.handle_chord(&a, chord("PGDN", {.Shift}))
    term_show(&a, tm, "more\r\n")
    doc = store.store_doc(&a.docs, tm.doc)
    testing.expect_value(t, s.view.top, max(txt.doc_line_count(doc) - app.panel_focused(&a).body.h, 0))
}

// Every run in the session's document, read back out of the SPAN STORE — the one door every
// document's colours come through (§5). A session has no second path.
@(private = "file")
term_all_styles :: proc(a: ^app.App, tm: ^app.Term) -> []view.Style {
    snap := store.store_snapshot(&a.docs, tm.doc)
    defer txt.snapshot_release(snap)
    return app.doc_styles(a, tm.doc, nil, &snap.text, nil, 0, txt.text_line_count(&snap.text))
}

// Colour is style runs (§5's span layer), not a second renderer. libvterm's colours are already
// resolved against the theme here, so nothing below the kernel knows what an SGR is.
@(test)
a_session_publishes_its_colours_as_style_runs :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    term_show(&a, tm, "\r\n\x1b[31mred\x1b[0m plain")
    line := term_line_of(&a, tm, "red plain")
    if !testing.expect(t, line >= 0, term_text(&a, tm)) {
        return
    }
    runs := 0
    for st in term_all_styles(&a, tm) {
        if st.line != line {
            continue
        }
        runs += 1
        testing.expect_value(t, st.lo, 0)
        testing.expect_value(t, st.hi, 3) // "red", and the plain tail publishes nothing
        testing.expect(t, st.fg != a.theme[.Fg], "the run kept the theme's foreground")
    }
    testing.expect_value(t, runs, 1)
}

// The scrollback cap: the oldest lines go, and document line 0, `base` and every frozen style
// run move together — a run that survives the trim still names the line it colours.
@(test)
the_scrollback_cap_moves_lines_and_styles_together :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t, 20, 4)
    if !ok {
        return
    }
    defer close_app(&a)

    head := pty.SCROLLBACK_TRIM * 4
    term_show(&a, tm, strings.repeat("x\r\n", head, context.temp_allocator))
    term_show(&a, tm, "\x1b[35mmark\x1b[0m\r\n")
    term_show(&a, tm, strings.repeat("y\r\n", pty.SCROLLBACK_MAX - head, context.temp_allocator))
    // The mark is frozen scrollback now; this batch crosses the cap and the oldest lines go.
    term_show(&a, tm, strings.repeat("z\r\n", pty.SCROLLBACK_TRIM * 2, context.temp_allocator))

    testing.expect(t, tm.base > 0, "the cap never crossed")
    testing.expect_value(t, tm.base, pty.terminal_oldest(&tm.t))
    doc := store.store_doc(&a.docs, tm.doc)
    testing.expect_value(t, txt.doc_line_count(doc), len(tm.t.scrollback) + tm.t.rows)

    line := term_line_of(&a, tm, "mark")
    if !testing.expect(t, line >= 0, "the marked line went with the trim") {
        return
    }
    // The shell's late prompt can share the mark's row, so find the mark's own bytes.
    off := strings.index(string(txt.doc_line(doc, line)), "mark")
    kept := false
    for st in term_all_styles(&a, tm) {
        kept ||= st.line == line && st.lo == off && st.hi == off + len("mark")
    }
    testing.expect(t, kept, "the mark's style run names the wrong cells")
}

// A blank cell on the default background is not worth keeping: it draws as nothing and pastes
// as a trailing space. One that carries a background is a TUI's bar, and losing it is losing
// what you can see.
@(test)
trailing_blanks_go_only_where_nothing_shows :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t, 20, 6)
    if !ok {
        return
    }
    defer close_app(&a)

    // The prompt first, or the shell writes it onto the row this is about to test.
    if !term_wait_for(t, &a, tm, "$") {
        return
    }
    term_show(&a, tm, "\r\nplain\r\n\x1b[44mbar\x1b[K\r\ntail")

    doc := store.store_doc(&a.docs, tm.doc)
    testing.expect_value(t, string(txt.doc_line(doc, term_line_of(&a, tm, "plain"))), "plain")
    // The same text with the rest of the row painted: there the blanks ARE the paint.
    testing.expect_value(t, len(txt.doc_line(doc, term_line_of(&a, tm, "bar"))), 20)
}

// A soft-wrapped command copies back as ONE line. libvterm knows which rows exist only because
// the one above them ran off the edge, and a command copied over that edge is one command.
@(test)
a_wrapped_line_copies_back_whole :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t, 10, 5)
    if !ok {
        return
    }
    defer close_app(&a)

    pty.terminal_resize(&tm.t, 4, 10)
    term_show(&a, tm, "\r\naaaaaaaaaabbb")
    line := term_line_of(&a, tm, "bbb")
    if !testing.expect(t, line > 0, term_text(&a, tm)) {
        return
    }
    doc := store.store_doc(&a.docs, tm.doc)
    txt.doc_set_head(doc, {line - 1, 0}, false)
    txt.doc_set_head(doc, {line, 3}, true)
    // Through the CHORD, not the proc: ctrl+c means copy in a session the same as anywhere
    // else, which is the row this gates as well as the unwrap above.
    app.handle_chord(&a, chord("AB03", {.Ctrl}))
    testing.expect_value(t, a.message, "copied")
}

// A TUI turning on tracking is a descriptor change, so the input funnel asks the same field it
// asks for every document and never learns what a terminal is.
@(test)
mouse_tracking_moves_to_the_descriptor :: proc(t: ^testing.T) {
    a, tm, ok := term_app(t)
    if !ok {
        return
    }
    defer close_app(&a)

    d := store.store_descriptor(&a.docs, tm.doc)
    testing.expect_value(t, d.mouse, desc.Mouse.Bound)
    desc.release(d)

    term_show(&a, tm, "\x1b[?1002h\x1b[?1006h") // DECSET: motion tracking, SGR encoding
    testing.expect(t, tm.t.mouse_on, "libvterm did not take the mode")
    d = store.store_descriptor(&a.docs, tm.doc)
    testing.expect_value(t, d.mouse, desc.Mouse.Events)
    desc.release(d)
    testing.expect(t, app.mouse_events_target(&a) != nil, "the funnel would still move point")

    term_show(&a, tm, "\x1b[?1002l\x1b[?1006l")
    d = store.store_descriptor(&a.docs, tm.doc)
    testing.expect_value(t, d.mouse, desc.Mouse.Bound)
    desc.release(d)
}

// The style runs the renderer is handed are the ones it paints, and only the cells they name.
@(test)
the_renderer_paints_a_style_run :: proc(t: ^testing.T) {
    d := desc.new_from({selection = .None})
    defer desc.release(d)
    doc: txt.Doc
    txt.doc_init(&doc)
    defer txt.doc_destroy(&doc)
    txt.doc_set_text(&doc, "abcdef")

    g: gfx.Grid
    if !testing.expect(t, gfx.grid_init(&g, 10, 1)) {
        return
    }
    defer gfx.grid_destroy(&g)
    th := gfx.DEFAULT_THEME
    red := [3]f32{1, 0, 0}
    snap := txt.doc_snapshot(&doc)
    defer txt.snapshot_release(snap)
    view.draw(&g, th, &snap.text, d, {}, 0, 0, 10, 1, {{line = 0, lo = 2, hi = 4, fg = red}})
    testing.expect_value(t, gfx.grid_at(&g, 1, 0).fg, th[.Fg])
    testing.expect_value(t, gfx.grid_at(&g, 2, 0).fg, red)
    testing.expect_value(t, gfx.grid_at(&g, 3, 0).fg, red)
    testing.expect_value(t, gfx.grid_at(&g, 4, 0).fg, th[.Fg])
}

// The VT core alone: resize reshapes the grid and cells stay readable.
@(test)
the_vt_core_resizes :: proc(t: ^testing.T) {
    tm: pty.Terminal
    pty.terminal_vt_init(&tm, 4, 10)
    defer pty.terminal_vt_destroy(&tm)

    pty.terminal_feed(&tm, transmute([]u8)string("hello"))
    testing.expect_value(t, pty.terminal_cell_rune(&tm, 0, 4), 'o')

    pty.terminal_resize(&tm, 6, 20)
    testing.expect_value(t, tm.rows, 6)
    testing.expect_value(t, tm.cols, 20)
    testing.expect_value(t, pty.terminal_cell_rune(&tm, 0, 0), 'h')
}

// ptsname answers through one static buffer: spawns racing it can cross-wire their slaves onto
// a shared pts and leave an orphaned master blocking its reader. Every shell must sit on its
// own tty.
@(test)
parallel_spawns_get_distinct_ttys :: proc(t: ^testing.T) {
    N :: 6
    terms: [N]pty.Terminal
    oks: [N]bool
    ths: [N]^thread.Thread
    for i in 0 ..< N {
        ths[i] = thread.create_and_start_with_poly_data2(
            &terms[i],
            &oks[i],
            proc(tm: ^pty.Terminal, ok: ^bool) {ok^ = pty.terminal_spawn(tm, 6, 60)},
        )
    }
    for th in ths {
        thread.join(th)
        thread.destroy(th)
    }
    defer for &tm, i in terms {
        if oks[i] {
            pty.terminal_close(&tm)
        }
    }
    seen: [dynamic]string
    defer delete(seen)
    for &tm, i in terms {
        if !testing.expect(t, oks[i], "a parallel spawn failed") {
            continue
        }
        pty.terminal_write(&tm, transmute([]u8)string("tty\n"))
        path, answered := wait_tty_answer(t, &tm)
        if !answered {
            return // the defer above still closes every session
        }
        for other in seen {
            testing.expectf(t, other != path, "two shells share %s", path)
        }
        append(&seen, path)
    }
}

// The `tty` line, only once its digits have a terminator behind them — matching mid-stream
// would truncate /dev/pts/12 to /dev/pts/1 and collide with a real 1.
@(private = "file")
wait_tty_answer :: proc(t: ^testing.T, tm: ^pty.Terminal) -> (string, bool) {
    b := strings.builder_make(context.temp_allocator)
    for _ in 0 ..< TERM_WAIT_TRIES {
        pty.terminal_drain(tm)
        strings.builder_reset(&b)
        for row in 0 ..< tm.rows {
            for col in 0 ..< tm.cols {
                r := pty.terminal_cell_rune(tm, row, col)
                strings.write_rune(&b, r >= 0x20 ? r : ' ')
            }
            strings.write_byte(&b, '\n')
        }
        text := strings.to_string(b)
        if i := strings.last_index(text, "/dev/pts/"); i >= 0 {
            j := i + len("/dev/pts/")
            for j < len(text) && text[j] >= '0' && text[j] <= '9' {
                j += 1
            }
            if j < len(text) && j > i + len("/dev/pts/") {
                return strings.clone(text[i:j], context.temp_allocator), true
            }
        }
        time.sleep(TERM_WAIT_STEP)
    }
    testing.expect(t, false, "a shell never answered `tty`")
    return "", false
}

// A new session starts where N0's shell is standing (term.odin), read off /proc rather than
// asked for. And a `cd` into a directory that is then deleted reads as no answer at all: /proc
// spells it "/path (deleted)", which must never reach a spawn.
@(test)
a_new_session_starts_where_n0_stands :: proc(t: ^testing.T) {
    a, ok := bare_app(60, 6)
    if !ok {
        return
    }
    defer close_app(&a)
    dir, dok := scratch(t, "n0-cwd")
    if !dok {
        return
    }

    sys := app.sys_slot(&a)
    if !testing.expect(t, sys != nil, "no N0 to spawn") {
        return
    }
    n0 := app.term_of(&a, sys.doc)
    pty.terminal_write(&n0.t, transmute([]u8)fmt.tprintf("cd '%s'\n", dir))
    moved := false
    for _ in 0 ..< TERM_WAIT_TRIES {
        if strings.has_suffix(pty.terminal_cwd(&n0.t), "/n0-cwd") {
            moved = true
            break
        }
        time.sleep(TERM_WAIT_STEP)
    }
    if !testing.expectf(t, moved, "N0 never moved; cwd=%q", pty.terminal_cwd(&n0.t)) {
        return
    }

    id, made := app.term_open(&a)
    if !testing.expect(t, made, "no second shell to spawn") {
        return
    }
    tm := app.term_of(&a, id)
    followed := false
    for _ in 0 ..< TERM_WAIT_TRIES {
        if pty.terminal_cwd(&tm.t) == pty.terminal_cwd(&n0.t) {
            followed = true
            break
        }
        time.sleep(TERM_WAIT_STEP)
    }
    testing.expectf(t, followed, "the new session stands in %q, N0 in %q",
                    pty.terminal_cwd(&tm.t), pty.terminal_cwd(&n0.t))

    os.remove_all(dir)
    testing.expect_value(t, pty.terminal_cwd(&n0.t), "")
}

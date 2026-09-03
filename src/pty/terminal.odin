package pty

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import vt "../libvterm"
import "../wake"

// A terminal session: the libvterm VT state machine plus the PTY and child shell. A
// per-session reader thread does the one blocking read() on the master fd; vterm_* stays
// main-thread-only. The VT core is GL-free and shell-free, so tests drive it alone.
//
// Salvaged from Slopd src/pty/terminal.odin; the mouse's per-character selection stayed
// behind until oket grows mouse input.
Terminal :: struct {
    term:   vt.VTerm,
    screen: vt.Screen,
    state:  vt.State,
    rows:   int,
    cols:   int,

    // PTY + child shell. pty is the master fd (-1 when there is no child, e.g. a headless
    // test Terminal); alive drops to false when the shell exits (read EOF). It is the one
    // field the reader thread writes that is not `inbuf`, so it is touched atomically —
    // see terminal_alive.
    pty:   posix.FD,
    pid:   posix.pid_t,
    alive: bool,
    // Set before the reader is signalled: read() on a pty master does not always end when the
    // shell does, and a close that cannot be bounded wedges whoever called it.
    stopping: bool,

    // Reader thread -> main loop: the thread appends under lock and wakes the loop, which
    // drains into the parser. Only raw bytes cross threads, never a vterm_* call.
    reader:  ^thread.Thread,
    lock:    sync.Mutex,
    inbuf:   [dynamic]u8,
    feedbuf: [dynamic]u8,

    // For the CL chain runner: a wrapped command emits its exit code in a private OSC
    // (OSC_EXIT_TAG), recorded here with exit_id correlating it to the injection.
    fallbacks:  vt.StateFallbacks,
    osc_buf:    [64]u8,
    osc_len:    int,
    exit_ready: bool,
    exit_id:    u64,
    exit_code:  int,

    // Scrollback. `sb_total` counts every line ever pushed, giving each a stable absolute
    // number: scrollback[i] is sb_total-len+i, live row r is sb_total+r. There is no view and
    // no copy cursor here — the kernel's viewport and cursors are the document's (§11).
    callbacks:  vt.ScreenCallbacks,
    sb_ctx:     runtime.Context, // context the sb_* "c" callbacks allocate under
    scrollback: [dynamic]ScrollLine,
    sb_total:   int,

    on_altscreen: bool, // a TUI owns the screen; there is no scrollback to scroll into
    mouse_on:     bool, // the TUI enabled mouse tracking, so clicks are its input
}

// A clone of the cells libvterm handed us as the line scrolled off. Owned by the Terminal.
ScrollLine :: struct {
    cells:        []vt.ScreenCell,
    // The line above wrapped (libvterm's sb_pushline4) — what makes a copied soft-wrapped
    // command paste back as one line. Captured because libvterm forgets a row in history.
    continuation: bool,
}

// Lines kept, and the slack before trimming the oldest in one batch (amortised O(1) per line
// rather than an O(n) shift on every scrolled line).
SCROLLBACK_MAX :: 5000
SCROLLBACK_TRIM :: SCROLLBACK_MAX / 8

// UTF-8 in, hard-reset to a clean screen. Colours stay libvterm's palette until
// terminal_set_default_colors seeds the theme.
terminal_vt_init :: proc(t: ^Terminal, rows, cols: int) {
    t.rows = max(rows, 1)
    t.cols = max(cols, 1)
    t.pty = -1 // no child until terminal_spawn
    t.term = vt.new(c.int(t.rows), c.int(t.cols))
    vt.set_utf8(t.term, 1)
    t.screen = vt.obtain_screen(t.term)
    t.state = vt.obtain_state(t.term)
    // Without this DECSET 1049 is a no-op and a TUI paints over the primary grid, spilling
    // every redraw into our scrollback.
    vt.screen_enable_altscreen(t.screen, 1)
    vt.screen_reset(t.screen, 1)
}

terminal_vt_destroy :: proc(t: ^Terminal) {
    if t.term != nil {
        vt.free(t.term) // frees its screen + state too
        t.term = nil
        t.screen = nil
        t.state = nil
    }
    for line in t.scrollback {
        delete(line.cells)
    }
    delete(t.scrollback)
    t.scrollback = nil
}

// Called from draw; no-op when unchanged. TIOCSWINSZ makes the shell reflow (SIGWINCH).
terminal_resize :: proc(t: ^Terminal, rows, cols: int) {
    r, w := max(rows, 1), max(cols, 1)
    if r == t.rows && w == t.cols {
        return
    }
    t.rows, t.cols = r, w
    vt.set_size(t.term, c.int(r), c.int(w))
    if t.pty >= 0 {
        terminal_set_winsize(t, r, w)
    }
}

// The colours cells with no SGR request resolve to, so a fresh shell paints in our palette.
terminal_set_default_colors :: proc(t: ^Terminal, fg, bg: [3]f32) {
    vfg := vt_color(fg)
    vbg := vt_color(bg)
    vt.screen_set_default_colors(t.screen, &vfg, &vbg)
}

// Raw output bytes through the parser; the cell grid updates in place. flush_damage is a
// no-op for our poll-the-grid model, but keeps libvterm's bookkeeping tidy.
terminal_feed :: proc(t: ^Terminal, bytes: []u8) {
    if len(bytes) == 0 {
        return
    }
    vt.input_write(t.term, raw_data(bytes), c.size_t(len(bytes)))
    vt.screen_flush_damage(t.screen)
}

// ok=false out of range. Carries libvterm's raw fg/bg + attrs; the host resolves colours at
// draw time.
terminal_cell :: proc(t: ^Terminal, row, col: int) -> (cell: vt.ScreenCell, ok: bool) {
    if row < 0 || row >= t.rows || col < 0 || col >= t.cols {
        return {}, false
    }
    vt.screen_get_cell(t.screen, vt.Pos{row = c.int(row), col = c.int(col)}, &cell)
    return cell, true
}

// The primary rune (0 when blank). Combining marks are ignored on the monospace grid.
terminal_cell_rune :: proc(t: ^Terminal, row, col: int) -> rune {
    cell := terminal_cell(t, row, col) or_else vt.ScreenCell{}
    return rune(cell.chars[0])
}

terminal_cursor :: proc(t: ^Terminal) -> (row, col: int) {
    p: vt.Pos
    vt.state_get_cursorpos(t.state, &p)
    return int(p.row), int(p.col)
}

// Default fg/bg keep their flag for the caller to map onto the theme; the rest convert
// through libvterm's palette.
terminal_color :: proc(t: ^Terminal, col: vt.Color) -> (rgb: [3]f32, is_default: bool) {
    col := col
    if vt.color_is_default_fg(col) || vt.color_is_default_bg(col) {
        return {}, true
    }
    vt.screen_convert_color_to_rgb(t.screen, &col)
    return {f32(col.red) / 255, f32(col.green) / 255, f32(col.blue) / 255}, false
}

@(private = "file")
vt_color :: proc(rgb: [3]f32) -> vt.Color {
    return vt.Color {
        type  = 0, // RGB: type bit clear, no default flags
        red   = u8(clamp(rgb.r, 0, 1) * 255),
        green = u8(clamp(rgb.g, 0, 1) * 255),
        blue  = u8(clamp(rgb.b, 0, 1) * 255),
    }
}

// --- lines ---
// An absolute-numbered space: [oldest, sb_total) is captured scrollback and [sb_total, bottom]
// the live grid. The kernel reads it a line at a time and the document IS those lines, so
// nothing here holds a view, a top row or a selection.

terminal_oldest :: proc(t: ^Terminal) -> int {
    return t.sb_total - len(t.scrollback)
}

terminal_bottom :: proc(t: ^Terminal) -> int {
    return t.sb_total + t.rows - 1
}

// From the live grid when `n` is on-screen, else from captured scrollback.
terminal_line_cell :: proc(t: ^Terminal, n, col: int) -> (cell: vt.ScreenCell, ok: bool) {
    if n >= t.sb_total {
        return terminal_cell(t, n - t.sb_total, col)
    }
    idx := n - terminal_oldest(t)
    if idx < 0 || idx >= len(t.scrollback) {
        return {}, false
    }
    line := t.scrollback[idx]
    if col < 0 || col >= len(line.cells) {
        return {}, false
    }
    return line.cells[col], true
}

// A captured line keeps its capture width, a live row is the current grid width. One
// definition, so the line build and the blank trim agree about where a row ends.
terminal_line_width :: proc(t: ^Terminal, n: int) -> int {
    if n >= t.sb_total {
        return t.cols
    }
    idx := n - terminal_oldest(t)
    if idx < 0 || idx >= len(t.scrollback) {
        return 0
    }
    return len(t.scrollback[idx].cells)
}

// Did the line above wrap? A live row is libvterm's (state_get_lineinfo), a scrolled-off row
// is ours. Unanswerable after a resize pops one back — sb_popline has no 4-argument form.
terminal_continuation :: proc(t: ^Terminal, n: int) -> bool {
    if n >= t.sb_total {
        row := n - t.sb_total
        if row < 0 || row >= t.rows || t.state == nil {
            return false
        }
        li := vt.state_get_lineinfo(t.state, c.int(row))
        return li != nil && li.continuation
    }
    idx := n - terminal_oldest(t)
    if idx < 0 || idx >= len(t.scrollback) {
        return false
    }
    return t.scrollback[idx].continuation
}

// --- PTY + child shell --- Pure core:sys/posix; TIOCSWINSZ is the one foreign bit.

TIOCSWINSZ :: 0x5414 // Linux ioctl: set terminal window size
TIOCGPTN :: 0x80045430 // Linux ioctl: a master's pty number, for building the slave path

Winsize :: struct {
    ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
    ioctl :: proc(fd: posix.FD, request: c.ulong, argp: rawptr) -> c.int ---
}

// The VT machine, a master/slave PTY pair, and a forked child running $SHELL with the slave
// as its controlling terminal. On success a reader thread is pumping the master fd.
terminal_spawn :: proc(t: ^Terminal, rows, cols: int, cwd := "") -> bool {
    terminal_vt_init(t, rows, cols)
    vt.output_set_callback(t.term, term_output_cb, t) // query replies -> PTY master
    t.fallbacks = vt.StateFallbacks{osc = term_osc_cb} // exit-code OSC -> t.exit_*
    vt.screen_set_unrecognised_fallbacks(t.screen, &t.fallbacks, t)
    terminal_enable_scrollback(t)

    // CLOEXEC, or every OTHER session's exec'd shell inherits this master and holds it open
    // for the life of that shell.
    master := posix.posix_openpt({.RDWR, .NOCTTY, .CLOEXEC})
    if master < 0 {
        return false
    }
    // The slave path comes from the kernel by number, NEVER from ptsname: ptsname hands back
    // a static buffer, and two sessions spawning in parallel race on it — each shell then
    // opens the OTHER's slave, and the orphaned master blocks its reader forever.
    pn: c.uint
    if posix.grantpt(master) != .OK ||
       posix.unlockpt(master) != .OK ||
       ioctl(master, TIOCGPTN, &pn) != 0 {
        posix.close(master)
        return false
    }

    // Everything the child needs, built BEFORE the fork: in a multithreaded process it may
    // only touch pre-allocated memory until exec.
    name := fmt.ctprintf("/dev/pts/%d", pn)
    shell := term_shell()
    argv := []cstring{shell, nil}
    envp := term_build_env()
    // The child chdir's here before exec; empty leaves it in our own cwd.
    dir := cwd == "" ? cstring(nil) : strings.clone_to_cstring(cwd)
    defer {
        delete(shell)
        delete(dir)
        term_free_env(envp)
    }

    pid := posix.fork()
    if pid < 0 {
        posix.close(master)
        return false
    }
    if pid == 0 {
        // CHILD — pre-allocated cstrings only, no Odin allocation, ending in exec.
        if dir != nil {
            posix.chdir(dir) // best effort
        }
        posix.setsid() // new session; the first tty opened becomes controlling
        slave := posix.open(name, {.RDWR}) // no NOCTTY: claim it as the controlling tty
        if slave < 0 {
            posix._exit(127)
        }
        posix.dup2(slave, posix.STDIN_FILENO)
        posix.dup2(slave, posix.STDOUT_FILENO)
        posix.dup2(slave, posix.STDERR_FILENO)
        if slave > posix.STDERR_FILENO {
            posix.close(slave)
        }
        posix.close(master)
        posix.execve(shell, raw_data(argv), envp)
        posix._exit(127) // exec failed
    }

    reader_wakeup_armed()
    t.pty = master
    t.pid = pid
    sync.atomic_store(&t.alive, true)
    terminal_set_winsize(t, rows, cols)
    t.reader = thread.create(term_reader_proc)
    if t.reader == nil {
        terminal_close(t) // reaps the child, closes the master, frees the vt
        return false
    }
    t.reader.data = t
    thread.start(t.reader)
    return true
}

// Safe on a half-built or already-dead session.
terminal_close :: proc(t: ^Terminal) {
    if t.pid > 0 {
        // The GROUP (the child setsid'd, so -pid names it): a shell killed alone can leave a
        // child holding the slave, and the reader below never sees EOF. HUP first for a clean
        // exit; then KILL, because a caught HUP can be deferred forever — readline parked on
        // a bare ESC does exactly that — and only an uncatchable signal bounds the join.
        posix.kill(-t.pid, .SIGHUP)
        for _ in 0 ..< 30 {
            if !terminal_alive(t) { // the reader saw EOF: every slave holder is gone
                break
            }
            time.sleep(10 * time.Millisecond)
        }
        if terminal_alive(t) {
            posix.kill(-t.pid, .SIGKILL)
        }
    }
    if t.reader != nil {
        // Killing the shell is not enough to end the reader's read(): anything else holding
        // the slave keeps the master open, and then this join never returns. Seen for real —
        // a wedged worker with a dead shell, an open master and a reader parked in read().
        // So interrupt the read instead of trusting a condition we do not control. EINTR plus
        // `stopping` is the only exit the reader needs that does not depend on the far end.
        sync.atomic_store(&t.stopping, true)
        for _ in 0 ..< 200 {
            if !terminal_alive(t) { // the reader stores alive=false as it leaves
                break
            }
            posix.pthread_kill(t.reader.unix_thread, .SIGUSR1)
            time.sleep(5 * time.Millisecond)
        }
        thread.join(t.reader)
        thread.destroy(t.reader)
        t.reader = nil
    }
    if t.pid > 0 {
        status: c.int
        posix.waitpid(t.pid, &status, {})
        t.pid = 0
    }
    if t.pty >= 0 {
        posix.close(t.pty)
        t.pty = -1
    }
    delete(t.inbuf)
    delete(t.feedbuf)
    t.inbuf, t.feedbuf = nil, nil
    terminal_vt_destroy(t)
}

terminal_write :: proc(t: ^Terminal, bytes: []u8) {
    if t.pty < 0 || len(bytes) == 0 {
        return
    }
    posix.write(t.pty, raw_data(bytes), c.size_t(len(bytes)))
}

// Clipboard text made safe to send as keystrokes. Newlines become CR (what Enter sends; CRLF
// is one ending), tabs survive, every other C0 control is dropped — an ESC could otherwise
// forge the paste end marker and hand the shell the rest as commands.
terminal_paste_sanitize :: proc(text: string, alloc := context.allocator) -> []u8 {
    out := make([dynamic]u8, 0, len(text), alloc)
    for i := 0; i < len(text); i += 1 {
        switch b := text[i]; {
        case b == '\r' || b == '\n':
            append(&out, '\r')
            if b == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
                i += 1
            }
        case b == '\t' || b >= 0x20 && b != 0x7f: // >= 0x80 is UTF-8 and passes
            append(&out, b)
        }
    }
    return out[:]
}

// Sanitised bytes to the PTY inside bracketed-paste markers, so a multi-line paste lands in
// the line editor instead of executing line by line.
terminal_paste :: proc(t: ^Terminal, text: string) {
    bytes := terminal_paste_sanitize(text, context.temp_allocator)
    if len(bytes) == 0 {
        return
    }
    vt.keyboard_start_paste(t.term)
    terminal_write(t, bytes)
    vt.keyboard_end_paste(t.term)
}

// Reader bytes into the parser (main thread). The lock is held across the swap only — holding
// it through terminal_feed's whole state machine is backpressure on the PTY for no gain.
terminal_drain :: proc(t: ^Terminal) {
    sync.mutex_lock(&t.lock)
    if len(t.inbuf) == 0 {
        sync.mutex_unlock(&t.lock)
        return
    }
    t.inbuf, t.feedbuf = t.feedbuf, t.inbuf // feedbuf was cleared after the last parse
    sync.mutex_unlock(&t.lock)

    terminal_feed(t, t.feedbuf[:])
    clear(&t.feedbuf)
}

@(private = "file")
terminal_set_winsize :: proc(t: ^Terminal, rows, cols: int) {
    ws := Winsize {
        ws_row = u16(rows),
        ws_col = u16(cols),
    }
    ioctl(t.pty, TIOCSWINSZ, &ws)
}

// SIGUSR1 is the reader's wakeup: the handler does nothing, and its only job is to make a
// blocked read() return EINTR. No SA_RESTART, or the kernel would resume the read instead.
@(private = "file")
wakeup_once: sync.Once

@(private = "file")
reader_wakeup_armed :: proc() {
    sync.once_do(&wakeup_once, proc() {
        act: posix.sigaction_t
        act.sa_handler = proc "c" (_: posix.Signal) {}
        posix.sigemptyset(&act.sa_mask)
        act.sa_flags = {}
        posix.sigaction(.SIGUSR1, &act, nil)
    })
}

// One blocking read() on the master fd, append under lock, wake the loop. EOF or an error
// means the shell exited — mark dead and wake once more so the last bytes are drained. EINTR
// is retried: the child's SIGCHLD can land on this thread.
@(private = "file")
term_reader_proc :: proc(th: ^thread.Thread) {
    t := (^Terminal)(th.data)
    buf: [4096]u8
    for {
        n := posix.read(t.pty, raw_data(buf[:]), len(buf))
        if n > 0 {
            sync.mutex_lock(&t.lock)
            append(&t.inbuf, ..buf[:n])
            sync.mutex_unlock(&t.lock)
            wake.hook()
            continue
        }
        if n < 0 && posix.get_errno() == .EINTR {
            if sync.atomic_load(&t.stopping) {
                break // terminal_close woke us on purpose
            }
            continue
        }
        break // n == 0 (EOF) or a real error
    }
    sync.atomic_store(&t.alive, false)
    wake.hook()
}

// Stores a self-pointer in libvterm, so call it only once `t` has a stable address — the test
// core returns a Terminal by value and must call it on the settled copy.
terminal_enable_scrollback :: proc(t: ^Terminal) {
    // The "c" callbacks carry no Odin context; capture the caller's so scrollback is
    // allocated under the same allocator terminal_vt_destroy frees it with.
    t.sb_ctx = context
    t.callbacks = vt.ScreenCallbacks {
        sb_pushline4 = term_sb_pushline_cb,
        sb_popline   = term_sb_popline_cb,
        settermprop  = term_settermprop_cb,
    }
    vt.screen_set_callbacks(t.screen, &t.callbacks, t)
    // The 4-argument pushline: the 3-argument form drops the wrapped bit, and a copied
    // soft-wrapped command comes back in two pieces. Must precede the first scroll-off.
    vt.screen_callbacks_has_pushline4(t.screen)
}

// We track ALTSCREEN and MOUSE. While a TUI is up it owns scrolling, so the scroll verbs
// route there. "c" callback on the main thread — a flag write, no context needed.
@(private = "file")
term_settermprop_cb :: proc "c" (prop: c.int, val: rawptr, user: rawptr) -> c.int {
    t := (^Terminal)(user)
    switch prop {
    case vt.PROP_ALTSCREEN:
        t.on_altscreen = (^c.int)(val)^ != 0
    case vt.PROP_MOUSE:
        t.mouse_on = (^c.int)(val)^ != 0
    }
    return 1
}

// Clone the scrolled-off cells and bump the running total so absolute numbers stay stable,
// trimming the oldest in a batch past the cap. "c" callback — needs a context to alloc.
@(private = "file")
term_sb_pushline_cb :: proc "c" (cols: c.int, cells: [^]vt.ScreenCell, continuation: bool, user: rawptr) -> c.int {
    t := (^Terminal)(user)
    context = t.sb_ctx
    n := int(cols)
    line := ScrollLine {
        cells        = make([]vt.ScreenCell, n),
        continuation = continuation,
    }
    copy(line.cells, cells[:n])
    append(&t.scrollback, line)
    t.sb_total += 1
    if len(t.scrollback) > SCROLLBACK_MAX + SCROLLBACK_TRIM {
        for i in 0 ..< SCROLLBACK_TRIM {
            delete(t.scrollback[i].cells)
        }
        remove_range(&t.scrollback, 0, SCROLLBACK_TRIM)
    }
    return 1
}

// The screen grew taller: hand back the newest scrollback line, decrementing sb_total so its
// absolute number resolves to the live row it became. 0 on empty history leaves the row blank.
@(private = "file")
term_sb_popline_cb :: proc "c" (cols: c.int, cells: [^]vt.ScreenCell, user: rawptr) -> c.int {
    t := (^Terminal)(user)
    context = t.sb_ctx
    if len(t.scrollback) == 0 {
        return 0
    }
    line := pop(&t.scrollback)
    n := min(int(cols), len(line.cells))
    copy(cells[:n], line.cells[:n])
    // The buffer is libvterm's and is NOT pre-blanked: after a widen it is a fresh malloc. It
    // then walks all `cols` of it stepping by each cell's width, so a stale width of 0 never
    // terminates and a negative one writes off the front of the new grid. A line narrower than
    // `cols` is the ordinary case once the pane has been resized twice, so blank the tail.
    for i in n ..< int(cols) {
        cells[i] = {width = 1, fg = {type = vt.COLOR_DEFAULT_FG}, bg = {type = vt.COLOR_DEFAULT_BG}}
    }
    delete(line.cells)
    t.sb_total -= 1
    return 1
}

// libvterm's reply bytes (cursor reports, device attributes) straight to the shell.
@(private = "file")
term_output_cb :: proc "c" (s: [^]u8, len: c.size_t, user: rawptr) {
    t := (^Terminal)(user)
    if t.pty >= 0 {
        posix.write(t.pty, s, len)
    }
}

// The private OSC the CL chain runner wraps commands with: `OSC 697 ; <id> ; <code> ST`. The
// id correlates the report with the injection.
OSC_EXIT_TAG :: 697

// The payload may arrive in fragments; parse on the final piece.
@(private = "file")
term_osc_cb :: proc "c" (command: c.int, frag: vt.StringFragment, user: rawptr) -> c.int {
    if int(command) != OSC_EXIT_TAG {
        return 0
    }
    t := (^Terminal)(user)
    if frag.initial {
        t.osc_len = 0
    }
    for i in 0 ..< int(frag.len) {
        if t.osc_len < len(t.osc_buf) {
            t.osc_buf[t.osc_len] = frag.str[i]
            t.osc_len += 1
        }
    }
    if frag.final {
        term_parse_exit(t, t.osc_buf[:t.osc_len])
    }
    return 1
}

// Contextless so the "c" callback can call it; hence the hand-rolled digit parsing.
@(private = "file")
term_parse_exit :: proc "contextless" (t: ^Terminal, payload: []u8) {
    id: u64
    code: int
    neg := false
    i := 0
    for i < len(payload) && payload[i] != ';' {
        if d := payload[i]; d >= '0' && d <= '9' {
            id = id * 10 + u64(d - '0')
        }
        i += 1
    }
    if i >= len(payload) {
        return // malformed
    }
    for i += 1; i < len(payload); i += 1 {
        switch d := payload[i]; {
        case d == '-':
            neg = true
        case d >= '0' && d <= '9':
            code = code * 10 + int(d - '0')
        }
    }
    t.exit_code = neg ? -code : code
    t.exit_id = id
    t.exit_ready = true
}

// $SHELL when absolute, else /bin/sh. Absolute lets the child exec without a PATH search,
// which would allocate — forbidden across the fork.
@(private = "file")
term_shell :: proc() -> cstring {
    sh := os.get_env("SHELL", context.temp_allocator)
    if len(sh) > 0 && sh[0] == '/' {
        return strings.clone_to_cstring(sh)
    }
    return strings.clone_to_cstring("/bin/sh")
}

// The environment with TERM forced to xterm-256color, as execve wants it. Built pre-fork.
@(private = "file")
term_build_env :: proc() -> [^]cstring {
    env := make([dynamic]cstring)
    for e := posix.environ; e[0] != nil; e = e[1:] {
        if !strings.has_prefix(string(e[0]), "TERM=") {
            append(&env, e[0]) // borrow the static C string
        }
    }
    append(&env, strings.clone_to_cstring("TERM=xterm-256color"))
    append(&env, nil) // execve terminator
    return raw_data(env)
}

@(private = "file")
term_free_env :: proc(envp: [^]cstring) {
    // Only the TERM entry was cloned by us.
    for e := envp; e[0] != nil; e = e[1:] {
        if strings.has_prefix(string(e[0]), "TERM=") {
            delete(e[0])
        }
    }
    free(envp)
}

// The reader thread clears this at EOF while everyone else reads it per frame, so it crosses
// threads atomically rather than under t.lock: live-or-dead is the whole answer, and taking
// the lock for it would put the paint behind the shell's output.
terminal_alive :: proc(t: ^Terminal) -> bool {
    return sync.atomic_load(&t.alive)
}

// From the host's char feed. Shift is already baked into the codepoint, so the modifier is
// none.
terminal_input_rune :: proc(t: ^Terminal, r: rune) {
    vt.keyboard_unichar(t.term, u32(r), vt.MOD_NONE)
}

terminal_input_key :: proc(t: ^Terminal, key: vt.Key, mod: vt.Modifier) {
    vt.keyboard_key(t.term, key, mod)
}

// A cell and a button to the TUI, encoded to whatever tracking mode it turned on — SGR 1006
// where the program asked for it, X10 where it did not. libvterm owns the encoding (§8's
// terminal forwarding) and writes it through the output callback.
//
// The move goes first whether or not a button follows: a TUI reads motion reports off the same
// stream, and a button with no position is a click at wherever the last one was.
terminal_mouse_move :: proc(t: ^Terminal, row, col: int, mod: vt.Modifier) {
    vt.mouse_move(t.term, c.int(row), c.int(col), mod)
}

terminal_mouse_button :: proc(t: ^Terminal, button: int, pressed: bool, mod: vt.Modifier) {
    vt.mouse_button(t.term, c.int(button), pressed, mod)
}

// Ctrl+letter as a control unichar (Ctrl+C -> 0x03); GLFW emits no char event for these.
terminal_input_ctrl :: proc(t: ^Terminal, letter: rune) {
    vt.keyboard_unichar(t.term, u32(letter), vt.MOD_CTRL)
}

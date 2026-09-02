package main

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:sys/posix"
import "core:time"

// §10's fault recovery: a plugin that faults dies alone, and the kernel keeps running.
//
// The kernel `sigsetjmp`s before every call into plugin code and the handler `siglongjmp`s
// back out — recover, do not only report. That is only worth doing because two guards say
// when it is safe:
//
//   1. THE FAULTING PC IS INSIDE THAT PLUGIN'S `.so`. The kernel does not get to recover from
//      its own bugs, so a frame that is not the plugin's falls through and dies honestly.
//   2. THE KERNEL IS NOT MID-TRANSACTION. Outside an api call a plugin holds nothing of the
//      kernel's (§6), so the dangerous window is one function you control rather than the whole
//      dispatch.
//
// A hang takes the same path: the watchdog signals the thread that is stuck and the handler
// cannot tell the two apart. One mechanism, two failures.
//
// THE TWO FLAGS ARE ATOMIC, and that is not about threads. A plain bool lets the optimiser see
// the arm and the disarm with no opaque call between them, fold the store away and hand the
// handler a constant — silently, and only in a release build. Everything else the handler reads
// is published behind them: written before `armed` goes up, read after it has been seen.
//
// The state is per THREAD because the jump has to land on the stack that faulted.

foreign import libc_ "system:c"

@(default_calling_convention = "c")
foreign libc_ {
    // glibc's setjmp.h defines sigsetjmp as a macro over this, so there is no plain symbol.
    @(link_name = "__sigsetjmp")
    sigsetjmp :: proc(env: ^Jmp_Buf, savemask: c.int) -> c.int ---
    siglongjmp :: proc(env: ^Jmp_Buf, val: c.int) -> ! ---
    // Which mapped object an address belongs to, which is the whole of guard 1.
    dladdr :: proc(addr: rawptr, info: ^Dl_Info) -> c.int ---
}

// glibc's is 200 bytes. The slack costs nothing and a short one would be a stack smash.
Jmp_Buf :: struct #align(16) {
    _: [512]u8,
}

Dl_Info :: struct {
    dli_fname: cstring,
    dli_fbase: rawptr,
    dli_sname: cstring,
    dli_saddr: rawptr,
}

FAULT_SIGNALS :: [?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE}

// Far larger than any frame could want. A dispatch still on the stack past this is not slow,
// it is not coming back.
PLUG_HANG_MS :: 5000

@(private = "file")
Guard :: struct {
    env:   Jmp_Buf,
    ctx:   runtime.Context, // the arming frame's, so the recovery path can allocate again
    app:   ^App,
    who:   int, // the plugin on the stack
    base:  uintptr, // where its `.so` is mapped, for guard 1
    why:   string, // what the handler saw; always a literal, never built
    armed: bool, // atomics only, and the note above says why
    busy:  bool, // inside an api call, so the kernel's own structures are open
}

@(private = "file", thread_local)
g_guard: Guard

// Static rather than allocated: it must outlive nothing in particular, and a stack the handler
// runs on is the last thing that should depend on the allocator being intact.
@(private = "file", thread_local)
g_alt: [64 * 1024]u8

@(private = "file")
g_installed: bool

// --- install ---

// Takes the signals a plugin dies of, and puts the handler on a stack of its own so a plugin
// that ran the stack out is still catchable. The handlers are per process and the alt stack is
// per thread, so a second caller only registers its own stack.
fault_install :: proc() -> bool {
    // Only if this thread has none. A sanitizer build installs its own and then unmaps it at
    // thread exit, so replacing it is how an ASan run — the very build §10 asks you to develop
    // plugins against — dies in the runtime instead of in your plugin.
    old: posix.stack_t
    if posix.sigaltstack(nil, &old) != .OK || .DISABLE in old.ss_flags {
        ss := posix.stack_t {
            ss_sp   = &g_alt[0],
            ss_size = len(g_alt),
        }
        if posix.sigaltstack(&ss, nil) != .OK {
            return false
        }
    }
    if g_installed {
        return true
    }
    act: posix.sigaction_t
    act.sa_sigaction = fault_handler
    // No RESETHAND: recovering means the next fault has to find the handler still there.
    act.sa_flags = {.SIGINFO, .ONSTACK}
    posix.sigemptyset(&act.sa_mask)
    for sig in FAULT_SIGNALS {
        if posix.sigaction(sig, &act, nil) != .OK {
            return false
        }
    }
    g_installed = true
    return true
}

fault_ready :: proc() -> bool {
    return g_installed
}

// Where `dlopen` mapped the object this address is in, recorded at load so the handler need
// only compare (§10).
fault_object_base :: proc(addr: rawptr) -> uintptr {
    info: Dl_Info
    if addr == nil || dladdr(addr, &info) == 0 {
        return 0
    }
    return uintptr(info.dli_fbase)
}

// --- arming, and coming back ---

fault_armed :: proc() -> bool {
    return intrinsics.atomic_load(&g_guard.armed)
}

// The buffer plug_dispatch sigsetjmps into. It is the dispatching frame's, and nothing else
// may hold it.
fault_env :: proc() -> ^Jmp_Buf {
    return &g_guard.env
}

// Armed AFTER the sigsetjmp that fills the buffer, and nothing between the two can fault.
fault_arm :: proc(a: ^App, i: int, base: uintptr) {
    g := &g_guard
    g.ctx, g.app, g.who, g.base, g.why = context, a, i, base, ""
    intrinsics.atomic_store(&g.busy, false)
    intrinsics.atomic_store(&g.armed, true)
    watch_arm()
}

fault_disarm :: proc() {
    intrinsics.atomic_store(&g_guard.armed, false)
    watch_clear()
}

// The window guard 2 names. Between these the kernel is writing its own structures on a
// plugin's behalf, and a fault there is not one to unwind out of.
fault_busy :: proc "contextless" (on: bool) {
    intrinsics.atomic_store(&g_guard.busy, on)
}

// Back from the handler, in the frame that armed the net. It reads only the guard: a local of
// that frame is a register the jump was never promised to restore.
fault_reap :: proc "contextless" () {
    context = g_guard.ctx
    plug_faulted(g_guard.app, g_guard.who, g_guard.why)
}

// --- the handlers ---
//
// Async-signal-safe: no allocation, no lock, no fmt. `dladdr` is the one call that is not on
// the list — it takes the loader's lock — and the window where that matters is a plugin
// faulting inside a `dlopen` it made itself.

@(private = "file")
fault_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) {
    if !recoverable(fault_ip(uc)) {
        die(sig)
        return
    }
    unwind(signal_name(sig))
}

// A dispatch that has not come back inside the deadline. Delivered to the thread that is stuck,
// so there is a frame to jump out of.
@(private = "file")
hang_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) {
    if !intrinsics.atomic_load(&g_guard.armed) {
        return // a stale alarm: the dispatch came back as the watcher fired
    }
    if intrinsics.atomic_load(&g_watch_until) != 0 {
        // Also stale: the watcher zeroes the deadline before it fires, so a live one belongs
        // to a NEWER dispatch that armed while the alarm was in flight.
        return
    }
    if intrinsics.atomic_load(&g_guard.busy) {
        // Stuck holding the kernel's own structures. Returning resumes the loop that never
        // ends, and a frozen window with no report is worse than a named death.
        die(.SIGABRT)
        return
    }
    unwind("stopped returning")
}

@(private = "file")
unwind :: proc "contextless" (why: string) {
    g_guard.why = why
    intrinsics.atomic_store(&g_guard.armed, false)
    watch_clear()
    siglongjmp(&g_guard.env, 1)
}

@(private = "file")
recoverable :: proc "contextless" (pc: uintptr) -> bool {
    g := &g_guard
    if !intrinsics.atomic_load(&g.armed) || intrinsics.atomic_load(&g.busy) {
        return false
    }
    info: Dl_Info
    if pc == 0 || g.base == 0 || dladdr(rawptr(pc), &info) == 0 {
        return false
    }
    return uintptr(info.dli_fbase) == g.base
}

// The kernel's own bug, or a plugin's in a window that cannot be unwound. RESETHAND is not set,
// so the default action goes back by hand and the re-raise is what writes the core.
@(private = "file")
die :: proc "contextless" (sig: posix.Signal) {
    posix.signal(sig, auto_cast posix.SIG_DFL)
    posix.kill(posix.getpid(), sig)
}

@(private = "file")
signal_name :: proc "contextless" (sig: posix.Signal) -> string {
    #partial switch sig {
    case .SIGSEGV:
        return "faulted (SIGSEGV)"
    case .SIGBUS:
        return "faulted (SIGBUS)"
    case .SIGILL:
        return "faulted (SIGILL)"
    case .SIGFPE:
        return "faulted (SIGFPE)"
    }
    return "faulted"
}

// Linux hands the handler a ucontext_t; Odin's core declares none and only the register block
// matters. Guarded on the arch as well: arm64 has a different mcontext.
when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
    @(private = "file")
    Uc_Stack :: struct {
        ss_sp:    rawptr,
        ss_flags: i32,
        _pad:     i32,
        ss_size:  uint,
    }

    @(private = "file")
    Ucontext :: struct {
        uc_flags: u64,
        uc_link:  rawptr,
        uc_stack: Uc_Stack,
        gregs:    [23]u64, // mcontext_t opens with gregset_t
    }

    @(private = "file")
    REG_RIP :: 16
    #assert(offset_of(Ucontext, gregs) == 40)

    @(private = "file")
    fault_ip :: proc "contextless" (uc: rawptr) -> uintptr {
        return uc == nil ? 0 : uintptr((^Ucontext)(uc).gregs[REG_RIP])
    }
} else {
    // No pc means guard 1 cannot answer, so nothing is recovered and every fault dies honestly.
    @(private = "file")
    fault_ip :: proc "contextless" (uc: rawptr) -> uintptr {
        return 0
    }
}

// --- the watchdog ---

@(private = "file")
g_watch_on: bool // whether a deadline is being kept, which is not the same as having a watcher
@(private = "file")
g_watch_live: bool // the watcher thread, started once and never stopped
@(private = "file")
g_watch_main: posix.pthread_t
@(private = "file")
g_watch_ms: i64
@(private = "file")
g_watch_tick: time.Duration
@(private = "file")
g_watch_until: i64 // monotonic nanoseconds; 0 while no plugin is on the stack

// One watcher, started by the thread that dispatches and watching only that thread.
fault_watchdog_start :: proc(ms := PLUG_HANG_MS) {
    if g_watch_on || !g_installed {
        return
    }
    act: posix.sigaction_t
    act.sa_sigaction = hang_handler
    act.sa_flags = {.SIGINFO, .ONSTACK}
    posix.sigemptyset(&act.sa_mask)
    if posix.sigaction(.SIGALRM, &act, nil) != .OK {
        return
    }
    g_watch_ms = i64(ms)
    g_watch_tick = time.Duration(clamp(i64(ms) / 4, 10, 200)) * time.Millisecond
    g_watch_main = posix.pthread_self()
    g_watch_on = true
    if g_watch_live {
        return
    }
    // A raw pthread rather than core:thread: this one never returns, so a Thread object would
    // be an allocation nothing ever frees.
    tid: posix.pthread_t
    if posix.pthread_create(&tid, nil, watchdog, nil) != nil {
        g_watch_on = false
        return
    }
    posix.pthread_detach(tid)
    g_watch_live = true
}

// The watcher stays and the deadline goes quiet. A session starts one watchdog and keeps it;
// this is for a caller that armed a short deadline of its own and must not leave it behind for
// whoever runs on this thread next.
fault_watchdog_stop :: proc() {
    watch_clear()
    g_watch_on = false
}

// It outlives every frame and the process ends with it. While nothing is on the stack it reads
// one atomic and sleeps, so a session with no plugin loaded pays nothing for it.
@(private = "file")
watchdog :: proc "c" (arg: rawptr) -> rawptr {
    context = runtime.default_context()
    for {
        time.sleep(g_watch_tick)
        until := intrinsics.atomic_load(&g_watch_until)
        if until == 0 || time.tick_now()._nsec <= until {
            continue
        }
        // Cleared first, and fired once: a second alarm into a handler that is already
        // unwinding would arrive on a stack that is being left.
        intrinsics.atomic_store(&g_watch_until, 0)
        // Targeted rather than posix.kill, which is process-directed: a PTY reader thread
        // would take the alarm as often as the one that is stuck.
        posix.pthread_kill(g_watch_main, .SIGALRM)
    }
}

// Armed with the net rather than at each dispatch site, so a call that reaches a plugin at all
// is watched.
@(private = "file")
watch_arm :: proc() {
    if watching() {
        intrinsics.atomic_store(&g_watch_until, time.tick_now()._nsec + g_watch_ms * 1e6)
    }
}

@(private = "file")
watch_clear :: proc "contextless" () {
    if watching() {
        intrinsics.atomic_store(&g_watch_until, 0)
    }
}

// The deadline belongs to the watched thread, and neither setting nor CLEARING it is anyone
// else's business: a clear from another thread's dispatch is a watchdog that never fires, and
// an alarm raised for one would land on a stack with no net in it.
@(private = "file")
watching :: proc "contextless" () -> bool {
    return g_watch_on && posix.pthread_equal(posix.pthread_self(), g_watch_main)
}

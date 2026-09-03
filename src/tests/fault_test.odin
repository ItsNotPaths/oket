package tests

import "core:dynlib"
import "core:strings"
import "core:testing"
import "../gfx"
import "../store"
import app "../oket"

// Stage 9's gate (§13): a deliberately null-dereferencing plugin dies alone and is named in the
// bar. The subject is src/tests/boom, which faults and hangs on purpose and is a fixture rather
// than a plugin — plugins/ is what release.sh ships.
//
// What these are really asking is whether §10's two guards hold: recovery happens only when the
// faulting frame is the plugin's own, and only when the kernel is not mid-transaction.

@(private = "file")
boom_app :: proc(t: ^testing.T, name: string) -> (a: app.App, ok: bool) {
    a = plug_app(t, name, "src/tests/boom") or_return
    app.plug_init(&a)
    if !testing.expect(t, app.fault_install(), "the fault net did not install") {
        close_plug_app(&a)
        return {}, false
    }
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "boom")), a.message) {
        close_plug_app(&a)
        return {}, false
    }
    // Something in the ring, so "alone" is observable: the kernel has to still be drawing this
    // after the plugin is gone.
    app.ring_add(&a, listing_doc(&a, a.home))
    return a, true
}

// The gate. A plugin dereferences null in its own code, and the kernel unloads it, says so, and
// carries on drawing the document it already had.
@(test)
a_faulting_plugin_dies_alone_and_is_named :: proc(t: ^testing.T) {
    a, ok := boom_app(t, "oket-fault-gate")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.cl_exec(&a, ":boom")

    testing.expect(t, app.plug_find(&a, "boom") < 0, "the plugin outlived its own fault")
    bar := app.bar_text(&a)
    testing.expect(t, strings.contains(bar, "boom"), bar)
    testing.expect(t, strings.contains(bar, "SIGSEGV"), bar)
    // Alone: the ring, the store and the renderer are untouched by somebody else's fault.
    app.surface_draw(&a)
    drawn := gfx.grid_snapshot(&a.panel, context.temp_allocator)
    testing.expect(t, strings.contains(drawn, "alpha.txt"), drawn)
    // And the command line still answers, which is the difference between recovering and
    // limping.
    app.cl_exec(&a, ":boom")
    testing.expect(t, strings.contains(app.bar_text(&a), "not a builtin"), app.bar_text(&a))
}

// A fault does not quarantine (§14): the author's loop is fix, `:pluginify`, load, so an
// explicit load takes the plugin again in the same session — same slot, fault flag gone.
@(test)
a_faulted_plugin_loads_again_when_asked :: proc(t: ^testing.T) {
    a, ok := boom_app(t, "oket-fault-again")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.cl_exec(&a, ":boom")
    testing.expect(t, app.plug_find(&a, "boom") < 0, "the plugin outlived its own fault")

    testing.expect(t, app.plug_load(&a, app.plug_path(&a, "boom")), a.message)
    testing.expect(t, app.plug_find(&a, "boom") >= 0, "a fault quarantined the plugin")
    _, named := app.kind_named(&a, "boom")
    testing.expect(t, named, "the reload registered nothing")
}

// A plugin that stops returning is the other half of §10's one mechanism: the watchdog signals
// the thread that is stuck and the handler cannot tell it from a fault.
@(test)
a_hang_dies_the_same_way_as_a_fault :: proc(t: ^testing.T) {
    a, ok := boom_app(t, "oket-fault-hang")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    // Far below PLUG_HANG_MS so the test is a second rather than five. Stopped again on the way
    // out: the runner shares threads between tests, and a deadline this short left armed is one
    // somebody else's dispatch would eventually trip.
    app.fault_watchdog_start(1000)
    defer app.fault_watchdog_stop()

    app.cl_exec(&a, ":hang") // it sleeps for five seconds; the watchdog is what ends the call

    testing.expect(t, app.plug_find(&a, "boom") < 0, "a plugin that never returned is still in")
    bar := app.bar_text(&a)
    testing.expect(t, strings.contains(bar, "stopped returning"), bar)
}

// A fault inside `open` is the one that leaves work half done: the kernel makes the document
// and its descriptor before the plugin's code runs, so the document has to go back.
@(test)
a_fault_while_opening_leaves_no_half_made_document :: proc(t: ^testing.T) {
    a, ok := boom_app(t, "oket-fault-open")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    kind, named := app.kind_named(&a, "boom")
    testing.expect(t, named, "the kind it registered is not in the table")

    // A slot on the free list, so the doomed document is guaranteed to take THAT one.
    spare := store.store_open(&a.docs)
    store.store_close(&a.docs, spare)

    _, opened := app.kind_fresh(&a, kind)
    testing.expect(t, !opened, "an open that faulted reported a document")

    // Free again, which is only true if the half-made document was closed on the way out.
    again := store.store_open(&a.docs)
    testing.expect_value(t, again.slot, spare.slot)
    store.store_close(&a.docs, again)
    testing.expect(t, app.plug_find(&a, "boom") < 0, "the plugin outlived its own fault")
}

// §10's first guard, on its own: recovery is gated on the faulting pc being inside THAT
// plugin's `.so`. The kernel does not get to recover from its own bugs, and this is the
// comparison that says so.
@(test)
the_guard_tells_a_plugins_code_from_the_kernels :: proc(t: ^testing.T) {
    a, ok := boom_app(t, "oket-fault-guard")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    i := app.plug_find(&a, "boom")
    entry, found := dynlib.symbol_address(a.plugs[i].lib, "oket_main")
    testing.expect(t, found, "the plugin exports no entry point")
    testing.expect(t, a.plugs[i].base != 0, "the load recorded no base address")
    testing.expect_value(t, app.fault_object_base(entry), a.plugs[i].base)
    // A kernel address answers with the kernel's own object, so a fault there falls through to
    // dying honestly however deep in a dispatch it happens.
    kernel := app.fault_object_base(rawptr(app.plug_find))
    testing.expect(t, kernel != 0 && kernel != a.plugs[i].base, "the kernel looks like a plugin")
}

// The invariant checks (§10), which need no signal: a plugin that returns cleanly having
// smashed a document is caught after the call that did it, and named for it. They run on every
// dispatch, net or no net, because they cost three O(1) reads per open document.
@(test)
a_document_smashed_under_a_dispatch_is_caught :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-fault-invariant")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "hello")), a.message) {
        return
    }
    kind, _ := app.kind_named(&a, "hello")
    id, opened := app.kind_fresh(&a, kind)
    testing.expect(t, opened, "the kind opened nothing")
    app.ring_add(&a, id)

    // A wild store, standing in for the one a plugin walking off a snapshot would make.
    store.store_doc(&a.docs, id).magic = 0
    app.cl_exec(&a, ":hello")

    testing.expect(t, app.plug_find(&a, "hello") < 0, "corrupting a document cost nothing")
    bar := app.bar_text(&a)
    testing.expect(t, strings.contains(bar, "hello"), bar)
    testing.expect(t, strings.contains(bar, "corrupt"), bar)
}

// Autoload (§14). It leans on the net: a plugin that dies on load must not make oket
// unstartable.
@(test)
autoload_takes_every_so_in_the_plugin_directory :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-fault-autoload")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)

    app.plug_autoload(&a)

    testing.expect(t, app.plug_find(&a, "hello") >= 0, a.message)
    _, named := app.kind_named(&a, "hello")
    testing.expect(t, named, "it loaded without registering")
}

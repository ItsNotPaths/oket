package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import app "../oket"

// Stage 12's gate (§13), the plugin half: an LSP round trip with nothing on a plugin thread.
// The kernel half is io_test.odin, which drives the pool directly.
//
// The subject is src/tests/lsp, a fixture that speaks LSP framing over one of §9's I/O jobs,
// and a shell script standing in for the server. The fixture itself checks the thread it is
// called on, so "not on a plugin thread" is asserted where it can actually be seen — every
// assertion below reads `a.message`, and OFF THREAD would land there instead.

// A server in POSIX sh: read the header, read exactly the body it names, answer with the byte
// count it read. Answering with the COUNT is what makes this a round trip — a reply proves the
// request arrived whole, where an echo would only prove a pipe is connected.
@(private = "file")
SERVER :: `
len=
while IFS= read -r line; do
    case "$line" in
        Content-Length:*) len=$(printf '%s' "$line" | tr -d '\r' | cut -d' ' -f2) ;;
        *)
            if [ -n "$len" ]; then
                body=$(dd bs=1 count="$len" 2>/dev/null)
                resp="{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"got\":${#body}}}"
                printf 'Content-Length: %d\r\n\r\n%s' "${#resp}" "$resp"
                exit 0
            fi
            ;;
    esac
done
`

@(private = "file")
lsp_app :: proc(t: ^testing.T, name: string) -> (a: app.App, ok: bool) {
    a = plug_app(t, name, "src/tests/lsp") or_return
    app.plug_init(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "lsp")), a.message) {
        close_plug_app(&a)
        return {}, false
    }
    return a, true
}

@(private = "file")
script :: proc(a: ^app.App, name, body: string) -> string {
    path, _ := filepath.join({a.home, name}, context.temp_allocator)
    _ = os.write_entire_file(path, transmute([]u8)body)
    return path
}

// THE GATE. A request goes out, a server reads it, an answer comes back, and the plugin is
// called on the main thread to be told.
@(test)
a_language_server_answers_and_nothing_ran_on_a_plugin_thread :: proc(t: ^testing.T) {
    a, ok := lsp_app(t, "oket-lsp-gate")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.cl_exec(&a, fmt.tprintf(":lsp %s", script(&a, "server.sh", SERVER)))
    testing.expect(t, io_settle(&a, echo_line, "lsp: initialized"), a.message)
}

// A server that dies is an exit code, at the same handler and through the same message.
@(test)
a_server_that_exits_reports_its_code :: proc(t: ^testing.T) {
    a, ok := lsp_app(t, "oket-lsp-exit")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.cl_exec(&a, fmt.tprintf(":lsp %s", script(&a, "dead.sh", "exit 4\n")))
    testing.expect(t, io_settle(&a, echo_line, "lsp: server exited 4"), a.message)
}

// Closing is silent (§9): a job the holder ended is not one it needs telling about, so no
// `.Io_End` follows and the last thing said stays said.
@(test)
a_closed_server_is_not_reported :: proc(t: ^testing.T) {
    a, ok := lsp_app(t, "oket-lsp-close")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.cl_exec(&a, fmt.tprintf(":lsp %s", script(&a, "slow.sh", "sleep 30\n")))
    app.cl_exec(&a, ":lsp stop")
    for _ in 0 ..< 100 {
        app.io_pump(&a)
        time.sleep(5 * time.Millisecond)
    }
    testing.expect_value(t, a.message, "lsp: stopped")
}

// A plugin's children die with it. Nothing observable is left behind, and the unload must not
// leave a job whose answers have nobody to go to.
@(test)
an_unloaded_plugin_takes_its_server_with_it :: proc(t: ^testing.T) {
    a, ok := lsp_app(t, "oket-lsp-unload")
    if !ok {
        return
    }
    defer close_plug_app(&a)

    app.cl_exec(&a, fmt.tprintf(":lsp %s", script(&a, "slow.sh", "sleep 30\n")))
    testing.expect(t, app.plug_unload(&a, app.plug_find(&a, "lsp")), "the plugin did not unload")
    for _ in 0 ..< 100 {
        app.io_pump(&a) // a completion for a plugin that is gone must reach nobody
        time.sleep(5 * time.Millisecond)
    }
    testing.expect_value(t, len(a.io_jobs), 0)
}

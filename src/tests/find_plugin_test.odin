package tests

import "core:testing"
import "../store"
import "../txt"
import app "../oket"

// plugins/find: `:find <text>` on the open line marks every match in the focused document before
// enter, and down moves the one enter would land on.

REVERSE :: u8(1 << 3) // OKET_ATTR_REVERSE

// The plugin's runs over `id`, as [lo, reversed] pairs.
@(private = "file")
marks :: proc(a: ^app.App, id: store.Id) -> [dynamic][2]int {
    out := make([dynamic][2]int, context.temp_allocator)
    who := app.producer_intern(a, "find")
    for sp in store.store_spans(a.docs, id, 0, txt.doc_len(store.store_doc(a.docs, id)),
                                []store.Producer{who}) {
        append(&out, [2]int{sp.lo, int(sp.attrs & REVERSE != 0)})
    }
    return out
}

// One frame: the watchers hear what moved, and what they wrote lands.
@(private = "file")
frame :: proc(a: ^app.App) {
    app.plug_pump(a)
    app.docs_settle(a)
}

@(test)
find_marks_matches_while_typed_and_down_steps_them :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-find-preview", "plugins/find")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    if !testing.expect(t, app.plug_load(&a, app.plug_path(&a, "find")), a.message) {
        return
    }
    id := scratch_doc(&a, "note", "foo one\nfoo two\nbar foo")
    app.ring_add(&a, id)

    app.cl_show(&a, ":find foo && printf bar | sort")
    frame(&a)
    got := marks(&a, id)
    testing.expect_value(t, len(got), 3)
    if len(got) == 3 {
        testing.expect_value(t, got[0], [2]int{0, 1}) // the caret is at 0, so enter lands here
        testing.expect_value(t, got[1], [2]int{8, 0})
    }

    app.handle_chord(&a, chord("DOWN"))
    frame(&a)
    got = marks(&a, id)
    if testing.expect_value(t, len(got), 3) {
        testing.expect_value(t, got[1], [2]int{8, 1})
    }
    testing.expect(t, app.cl_active(&a), "down closed the line")

    app.handle_chord(&a, chord("ESC"))
    frame(&a)
    testing.expect_value(t, len(marks(&a, id)), 0)
}

package tests

import "core:os"
import "core:strings"
import "core:testing"
import "../input"
import app "../oket"

// binds.conf ships complete: the file a first start writes holds every default, a row the user
// deletes is reported, and `none` is how a chord is unbound on purpose.

@(private = "file")
shipped :: proc(t: ^testing.T, name: string) -> (a: app.App, dir: string, ok: bool) {
    dir = scratch(t, name) or_return
    a = bare_app() or_return
    app.app_home(&a, dir)
    app.binds_sync(&a)
    return a, dir, true
}

// Every default answers from a FILE row with the same target, so the code table is only ever a
// fallback.
@(test)
the_shipped_file_is_the_defaults :: proc(t: ^testing.T) {
    a, dir, ok := shipped(t, "oket-binds-shipped")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    testing.expect_value(t, len(a.gripes), 0)
    testing.expect_value(t, len(app.binds_missing(&a)), 0)
    base := app.binds_base()
    defer input.binds_destroy(&base)
    for d in base {
        for ctx in d.ctx {
            b, found := input.bind_at(a.binds[:], d.chord, ctx, d.kind, d.prefix)
            testing.expectf(t, found && b.origin.src == .Config && b.target == d.target,
                            "%v in %v is not the file's", d.chord, ctx)
        }
    }
}

// A deleted row is reported and the default still runs; the same chord as `none` is not
// reported and resolves to nothing, not to a wider row.
@(test)
a_deleted_row_is_reported_and_none_unbinds :: proc(t: ^testing.T) {
    a, dir, ok := shipped(t, "oket-binds-none")
    if !ok {
        return
    }
    defer os.remove_all(dir)
    defer close_app(&a)

    path := app.binds_path(&a)
    raw, _ := os.read_entire_file(path, context.temp_allocator)
    text := string(raw)
    row := ""
    rest := text
    for line in strings.split_lines_iterator(&rest) {
        if strings.has_suffix(line, " = search.next") {
            row = line
        }
    }
    if !testing.expect(t, row != "", "no search.next row in the shipped file") {
        return
    }
    gone, _ := strings.replace(text, strings.concatenate({row, "\n"}, context.temp_allocator), "", 1,
                               context.temp_allocator)
    _ = os.write_entire_file(path, transmute([]u8)gone)
    app.binds_sync(&a)

    missing := app.binds_missing(&a)
    testing.expect_value(t, len(missing), 1)
    if len(missing) == 1 {
        testing.expect(t, strings.has_suffix(missing[0], " = search.next"))
    }
    f3, _ := input.key_code("FK03")
    b, _, found := input.bind_lookup(a.binds[:], {f3, {}}, .Text)
    testing.expect(t, found && b.target == input.Bind_Target(input.Command.Search_Next),
                   "the default stopped running")

    key, _, _ := strings.partition(row, " = ")
    unbound, _ := strings.replace(text, row, strings.concatenate({key, " = none"}, context.temp_allocator),
                                  1, context.temp_allocator)
    _ = os.write_entire_file(path, transmute([]u8)unbound)
    app.binds_sync(&a)
    testing.expect_value(t, len(app.binds_missing(&a)), 0)
    _, _, found = input.bind_lookup(a.binds[:], {f3, {}}, .Text)
    testing.expect(t, !found, "a `none` row still resolves")
}

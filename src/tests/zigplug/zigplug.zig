// A whole plugin in Zig, which is the §8 claim: one command and one helper call. A fixture, so
// it sits under src/tests like boom.c and not in plugins/.
//
// `@cImport` reads oket_helpers.h, so the header IS the binding and its _Static_asserts are
// what make that safe. Nothing here is hand-declared.
const c = @cImport({
    @cInclude("oket_helpers.h");
});

const NAME = "zigplug";
const DOC = "proof the seam is not C-only";

fn said(api: [*c]const c.oket_api, self: c.oket_self, at: [*c]const c.oket_at,
        args: [*c]const u8, args_len: usize) callconv(.c) i32 {
    _ = at;
    _ = args;
    _ = args_len;
    c.oket_say(api, self, "hello from zig");
    return 0;
}

export fn oket_main(api: [*c]const c.oket_api, self: c.oket_self) callconv(.c) i32 {
    api.*.register_command.?(api, self, NAME, NAME.len, DOC, DOC.len, said);
    return 0;
}

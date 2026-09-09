// A whole plugin in Odin, which is the §8 claim: one command and one helper call. A fixture, so
// it sits under src/tests like boom.c and not in plugins/.
//
// `oket:` is the collection stage.sh points at the seam: `src/` in the repo, `helpers/odin/`
// beside an installed oket. Same import either place, because `plug` imports nothing but
// `core:c` and `shape` and both ship together.
package odinplug

import "base:runtime"
import "core:c"
import "oket:plug"

NAME := "odinplug"
DOC := "proof the seam is not C-only"

// The helpers are C and stay C. `odin build` drives the linker, so stage.sh hands it an
// archive and the symbol is resolved out of that.
@(default_calling_convention = "c")
foreign {
    oket_say :: proc(api: ^plug.Api, self: plug.Self, text: cstring) ---
}

// A plugin entry point is called from C, so it arrives with no context. Odin's default one is
// what every allocation in here would use, and nothing in here allocates.
said :: proc "c" (api: ^plug.Api, self: plug.Self, at: ^plug.At, args: [^]u8,
                  args_len: c.size_t) -> c.int32_t {
    context = runtime.default_context()
    oket_say(api, self, "hello from odin")
    return 0
}

@(export, link_name = "oket_main")
oket_main :: proc "c" (api: ^plug.Api, self: plug.Self) -> c.int32_t {
    context = runtime.default_context()
    api.register_command(api, self, raw_data(NAME), len(NAME), raw_data(DOC), len(DOC), said)
    return 0
}

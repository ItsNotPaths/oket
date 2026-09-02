package main

import "core:fmt"
import "core:strings"

// Stamped by the build (`-define:OKET_VERSION=v1.2.3`); "dev" for a plain `odin build`.
// `-define` PARSES its value, so the build quotes the tag and version_text strips the quotes;
// the %v keeps a bare numeric define printable too.
OKET_VERSION :: #config(OKET_VERSION, "dev")

version_text :: proc() -> string {
    return strings.trim(fmt.tprintf("%v", OKET_VERSION), `"`)
}

package input

import "core:fmt"
import "core:strconv"
import "core:strings"

// A key is stored by physical position, shown in the letters of the current layout (§6).
//
// The canonical code space is X keycodes: the numbers the XKB names in key_table.odin index.
// GLFW hands exactly these on X11 and evdev (keycode-8) on Wayland; Windows and macOS get a
// crossmapping table each when they land. A layout changes what a position types, never its
// code, so a bind survives a layout switch.
Code :: distinct u16

Mod :: enum u8 {
    Shift,
    Ctrl,
    Alt,
    Super,
}

Mods :: bit_set[Mod;u8]

Chord :: struct {
    code: Code,
    mods: Mods,
}

// Resolves a layout spelling ("j") to the position that types it. The front-end supplies it,
// so this package never touches the window system and tests fake a layout.
Layout_Resolve :: proc(name: string) -> (Code, bool)

// Names the glyph a position types under the current layout, "" for keys that type nothing.
Layout_Name :: proc(code: Code) -> string

// The primary XKB name, "" where no key has the code.
key_name :: proc(c: Code) -> string {
    for e in KEY_NAMES {
        if e.code == c {
            return e.name
        }
    }
    return ""
}

// Accepts aliases too: AC12 answers with BKSL's code.
key_code :: proc(name: string) -> (Code, bool) {
    for e in KEY_CODES {
        if e.name == name {
            return e.code, true
        }
    }
    return 0, false
}

code_is_modifier :: proc(c: Code) -> bool {
    switch key_name(c) {
    case "LFSH", "RTSH", "LCTL", "RCTL", "LALT", "RALT", "LWIN", "RWIN":
        return true
    }
    return false
}

@(rodata)
MOD_NAMES := [Mod]string {
    .Shift = "shift",
    .Ctrl  = "ctrl",
    .Alt   = "alt",
    .Super = "super",
}

// Display labels for keys a layout has no glyph for. Data, not policy: the physical spelling
// below is always accepted and always shown by describe.
@(rodata)
KEY_LABELS := [?]struct {
    name, label: string,
} {
    {"ESC", "esc"}, {"TAB", "tab"}, {"RTRN", "enter"}, {"KPEN", "kpenter"},
    {"BKSP", "backspace"}, {"SPCE", "space"}, {"CAPS", "caps"}, {"COMP", "menu"},
    {"LFSH", "lshift"}, {"RTSH", "rshift"}, {"LCTL", "lctrl"}, {"RCTL", "rctrl"},
    {"LALT", "lalt"}, {"RALT", "ralt"}, {"LWIN", "lsuper"}, {"RWIN", "rsuper"},
    {"UP", "up"}, {"DOWN", "down"}, {"LEFT", "left"}, {"RGHT", "right"},
    {"INS", "ins"}, {"DELE", "del"}, {"HOME", "home"}, {"END", "end"},
    {"PGUP", "pgup"}, {"PGDN", "pgdn"},
    {"PRSC", "print"}, {"SCLK", "scrolllock"}, {"PAUS", "pause"}, {"NMLK", "numlock"},
    {"FK01", "f1"}, {"FK02", "f2"}, {"FK03", "f3"}, {"FK04", "f4"}, {"FK05", "f5"},
    {"FK06", "f6"}, {"FK07", "f7"}, {"FK08", "f8"}, {"FK09", "f9"}, {"FK10", "f10"},
    {"FK11", "f11"}, {"FK12", "f12"},
    {"KP0", "kp0"}, {"KP1", "kp1"}, {"KP2", "kp2"}, {"KP3", "kp3"}, {"KP4", "kp4"},
    {"KP5", "kp5"}, {"KP6", "kp6"}, {"KP7", "kp7"}, {"KP8", "kp8"}, {"KP9", "kp9"},
    {"KPDV", "kp/"}, {"KPMU", "kp*"}, {"KPSU", "kp-"}, {"KPAD", "kp+"},
    {"KPDL", "kp."}, {"KPEQ", "kp="},
}

@(private = "file")
key_label :: proc(c: Code) -> string {
    name := key_name(c)
    for e in KEY_LABELS {
        if e.name == name {
            return e.label
        }
    }
    return ""
}

// Both config spellings (§6): the key part is a layout glyph ("j"), a display label ("f1"),
// or a physical position ("@AC06", "@57" for a code with no name).
chord_parse :: proc(text: string, resolve: Layout_Resolve) -> (c: Chord, ok: bool) {
    rest := text
    for {
        i := strings.index_byte(rest, '+')
        if i < 0 || i == len(rest) - 1 { // a trailing '+' is the + key itself
            break
        }
        mod_ok: bool
        for label, m in MOD_NAMES {
            if rest[:i] == label {
                c.mods += {m}
                mod_ok = true
            }
        }
        if !mod_ok {
            return {}, false
        }
        rest = rest[i + 1:]
    }
    if rest == "" {
        return {}, false
    }

    if rest[0] == '@' {
        if n, is_num := strconv.parse_uint(rest[1:]); is_num {
            c.code = Code(n)
            return c, c.code != 0
        }
        c.code = key_code(rest[1:]) or_return
        return c, true
    }
    if resolve != nil {
        if code, found := resolve(rest); found {
            c.code = code
            return c, true
        }
    }
    for e in KEY_LABELS {
        if e.label == rest {
            c.code = key_code(e.name) or_else 0
            return c, c.code != 0
        }
    }
    return {}, false
}

// The physical spelling, always valid to parse back: "alt+@AC06", "@57" for a nameless code.
chord_physical :: proc(c: Chord, allocator := context.allocator) -> string {
    b := builder_with_mods(c.mods, allocator)
    name := key_name(c.code)
    if name == "" {
        fmt.sbprintf(&b, "@%d", c.code)
    } else {
        strings.write_byte(&b, '@')
        strings.write_string(&b, name)
    }
    return strings.to_string(b)
}

// The layout spelling for display: the glyph the position types, a label for keys that type
// nothing, the physical spelling as the last resort.
chord_format :: proc(c: Chord, layout: Layout_Name, allocator := context.allocator) -> string {
    key := layout != nil ? layout(c.code) : ""
    if key == "" {
        key = key_label(c.code)
    }
    if key == "" {
        phys := chord_physical(c, context.temp_allocator)
        return strings.clone(phys, allocator)
    }
    b := builder_with_mods(c.mods, allocator)
    strings.write_string(&b, key)
    return strings.to_string(b)
}

@(private = "file")
builder_with_mods :: proc(mods: Mods, allocator := context.allocator) -> strings.Builder {
    b := strings.builder_make(allocator)
    for label, m in MOD_NAMES {
        if m in mods {
            strings.write_string(&b, label)
            strings.write_byte(&b, '+')
        }
    }
    return b
}

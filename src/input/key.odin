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

// `held` is a key that is DOWN, not a modifier: `Mods` is four members over a bit_set and tab
// cannot join them, so a chord names one instead (PANELS.md §6). Zero for every chord that is
// not part of a hold-steer-release gesture, which is all of them by default.
Chord :: struct {
    code: Code,
    mods: Mods,
    held: Code,
}

// Resolves a layout spelling ("j") to the position that types it. The front-end supplies it,
// so this package never touches the window system and tests fake a layout.
Layout_Resolve :: proc(name: string) -> (Code, bool)

// Names the glyph a position types under the current layout, "" for keys that type nothing.
Layout_Name :: proc(code: Code) -> string

// The primary XKB name, "" where no key has the code. A mouse code answers with its spelling,
// so every proc reading a name reaches the mouse without a branch of its own (mouse.odin).
key_name :: proc(c: Code) -> string {
    if m, is_mouse := mouse_of(c); is_mouse {
        return MOUSE_SPELLING[m]
    }
    for e in KEY_NAMES {
        if e.code == c {
            return e.name
        }
    }
    return ""
}

// Accepts aliases too: AC12 answers with BKSL's code, and `click` with the mouse's.
key_code :: proc(name: string) -> (Code, bool) {
    if code, is_mouse := mouse_named(name); is_mouse {
        return code, true
    }
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
    if code_is_mouse(c) {
        return name // "click" is the label and the spelling both
    }
    for e in KEY_LABELS {
        if e.name == name {
            return e.label
        }
    }
    return ""
}

// One key spelling, resolved: a mouse button, a physical position ("@AC06", "@57"), a layout
// glyph ("j"), or a display label ("f1"). Shared by the key a chord ends on and by a held one,
// so the two can never accept different spellings.
@(private = "file")
key_of :: proc(text: string, resolve: Layout_Resolve) -> (Code, bool) {
    if text == "" {
        return 0, false
    }
    if code, is_mouse := mouse_named(text); is_mouse {
        return code, true
    }
    if text[0] == '@' {
        if n, is_num := strconv.parse_uint(text[1:]); is_num {
            return Code(n), n != 0
        }
        return key_code(text[1:])
    }
    if resolve != nil {
        if code, found := resolve(text); found {
            return code, true
        }
    }
    for e in KEY_LABELS {
        if e.label == text {
            return key_code(e.name)
        }
    }
    return 0, false
}

@(private = "file")
mod_named :: proc(text: string) -> (Mod, bool) {
    for label, m in MOD_NAMES {
        if text == label {
            return m, true
        }
    }
    return .Shift, false
}

// Both config spellings (§6), and one name left of a `+` that is not a modifier is a key held
// DOWN: `tab+enter` is the picker's chord and is not the same chord as `enter` (PANELS.md §6).
// Only one key can be held, because only one field holds it.
chord_parse :: proc(text: string, resolve: Layout_Resolve) -> (c: Chord, ok: bool) {
    rest := text
    for {
        i := strings.index_byte(rest, '+')
        if i < 0 || i == len(rest) - 1 { // a trailing '+' is the + key itself
            break
        }
        if m, is_mod := mod_named(rest[:i]); is_mod {
            c.mods += {m}
        } else {
            if c.held != 0 {
                return {}, false
            }
            c.held = key_of(rest[:i], resolve) or_return
        }
        rest = rest[i + 1:]
    }
    c.code = key_of(rest, resolve) or_return
    return c, true
}

// The physical spelling, always valid to parse back: "alt+@AC06", "@57" for a nameless code,
// "@TAB+@RTRN" for a held chord.
chord_physical :: proc(c: Chord, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    write_mods(&b, c.mods)
    if c.held != 0 {
        write_physical(&b, c.held)
        strings.write_byte(&b, '+')
    }
    write_physical(&b, c.code)
    return strings.to_string(b)
}

// `"ctrl+b ctrl+f"`: a primer and the chord it qualifies, split on the space. Two and never
// three — a tree deeper than one level is a mode with extra steps.
//
// The primer must carry a modifier and must not be a mouse code: a button already moves point
// before dispatch, and an unmodified primer would swallow a key that types.
chord_pair_parse :: proc(text: string, resolve: Layout_Resolve) -> (prefix, c: Chord, ok: bool) {
    lo, _, hi := strings.partition(strings.trim_space(text), " ")
    if hi == "" {
        c = chord_parse(lo, resolve) or_return
        return {}, c, true
    }
    hi = strings.trim_space(hi)
    if strings.contains(hi, " ") {
        return {}, {}, false
    }
    prefix = chord_parse(lo, resolve) or_return
    c = chord_parse(hi, resolve) or_return
    if prefix.mods == {} || c.mods == {} || mouse_is(prefix.code) {
        return {}, {}, false
    }
    return prefix, c, true
}

// A primer and its child, spelled back the way the file writes them.
chord_pair_format :: proc(prefix, c: Chord, layout: Layout_Name,
                          allocator := context.allocator) -> string {
    if prefix == (Chord{}) {
        return chord_format(c, layout, allocator)
    }
    return strings.concatenate(
        {
            chord_format(prefix, layout, context.temp_allocator),
            " ",
            chord_format(c, layout, context.temp_allocator),
        },
        allocator,
    )
}

// The layout spelling for display: the glyph the position types, a label for keys that type
// nothing, the physical spelling as the last resort. A held key is a prefix like a modifier,
// so `tab+enter` reads as the gesture it is (PANELS.md §6).
chord_format :: proc(c: Chord, layout: Layout_Name, allocator := context.allocator) -> string {
    key := key_spelling(c.code, layout)
    if key == "" {
        phys := chord_physical(c, context.temp_allocator)
        return strings.clone(phys, allocator)
    }
    b := strings.builder_make(allocator)
    write_mods(&b, c.mods)
    if c.held != 0 {
        if h := key_spelling(c.held, layout); h != "" {
            strings.write_string(&b, h)
        } else {
            write_physical(&b, c.held)
        }
        strings.write_byte(&b, '+')
    }
    strings.write_string(&b, key)
    return strings.to_string(b)
}

// The glyph a position types, then a label for the keys that type nothing. "" for a code with
// neither, which is what sends chord_format to the physical spelling for the whole chord.
@(private = "file")
key_spelling :: proc(code: Code, layout: Layout_Name) -> string {
    if key := layout != nil ? layout(code) : ""; key != "" {
        return key
    }
    return key_label(code)
}

@(private = "file")
write_physical :: proc(b: ^strings.Builder, code: Code) {
    name := key_name(code)
    switch {
    case code_is_mouse(code):
        strings.write_string(b, name) // a button has one spelling; no layout can shift it
    case name == "":
        fmt.sbprintf(b, "@%d", code)
    case:
        fmt.sbprintf(b, "@%s", name)
    }
}

@(private = "file")
write_mods :: proc(b: ^strings.Builder, mods: Mods) {
    for label, m in MOD_NAMES {
        if m in mods {
            strings.write_string(b, label)
            strings.write_byte(b, '+')
        }
    }
}

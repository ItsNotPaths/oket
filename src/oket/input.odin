package main

import "base:runtime"
import "core:c"
import "vendor:glfw"
import glfwb "vendor:glfw/bindings"
import "../gfx"
import "../input"

// GLFW events in, one command out. No chords are written here: this normalizes the scancode or
// the button, asks the bind table, and runs what it names. Every keystroke and every click
// arrives through the one funnel, which is what makes macros and replay cheap later.

// GLFW's scancode is backend-shaped: raw evdev on Wayland, X keycodes (evdev+8) on X11. The
// kernel stores X keycodes, the space the XKB name table indexes.
@(private = "file")
scancode_shift: input.Code

// Set by input_init. A layout spelling cannot be resolved before it, and answering anyway is
// worse than refusing: see key_layout_code.
input_ready: bool

input_init :: proc(a: ^App) {
    if glfw.GetPlatform() == glfw.PLATFORM_WAYLAND {
        scancode_shift = 8
    }
    input_ready = true
    glfw.SetWindowUserPointer(a.window, a)
    glfw.SetKeyCallback(a.window, key_callback)
    glfw.SetCharCallback(a.window, char_callback)
    glfw.SetMouseButtonCallback(a.window, button_callback)
    glfw.SetCursorPosCallback(a.window, cursor_callback)
    glfw.SetScrollCallback(a.window, scroll_callback)
}

// --- the window's half ---

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || scancode <= 0 || action != glfw.PRESS && action != glfw.REPEAT {
        return
    }
    code := input.Code(scancode) + scancode_shift
    if input.code_is_modifier(code) {
        return // a held modifier is not a chord; wait for what it qualifies
    }
    handle_chord(a, input.Chord{code, glfw_mods(mods)})
}

// Text is not keys (§8): a rune arrives on its own channel, so a bind never sees an `a` on its
// way into a document and a document never has to guess which of the two it was handed.
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
    context = runtime.default_context()
    if a := (^App)(glfw.GetWindowUserPointer(window)); a != nil {
        text_input(a, codepoint)
    }
}

// A click is a chord, and it fires on RELEASE so a drag cancels it (§8).
button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || int(button) >= len(input.MOUSE_BUTTONS) {
        return
    }
    px, py := glfw.GetCursorPos(window)
    cx, cy := cell_at(a, px, py)
    if action == glfw.PRESS {
        // Point first, then the chord (§8): holes fill from point exactly as they do for a key.
        point_place(a, cx, cy)
        input.mouse_press(&a.mouse, input.MOUSE_BUTTONS[button], cx, cy)
        return
    }
    if m, fired := input.mouse_release(&a.mouse, cx, cy, glfw.GetTime()); fired {
        handle_chord(a, input.Chord{input.mouse_code(m), glfw_mods(mods)})
    }
}

// Dragging sweeps the selection; moving free updates what the pointer is offering.
cursor_callback :: proc "c" (window: glfw.WindowHandle, px, py: f64) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil {
        return
    }
    cx, cy := cell_at(a, px, py)
    if input.mouse_motion(&a.mouse, cx, cy) {
        point_drag(a, cx, cy)
        return
    }
    hover_update(a, cx, cy)
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoff, yoff: f64) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil {
        return
    }
    wheel := input.Mouse.Wheel_Up
    switch {
    case yoff < 0:
        wheel = .Wheel_Down
    case yoff == 0 && xoff > 0:
        wheel = .Wheel_Right
    case yoff == 0 && xoff < 0:
        wheel = .Wheel_Left
    case yoff == 0:
        return
    }
    handle_chord(a, input.Chord{input.mouse_code(wheel), glfw_mods_now(window)})
}

@(private = "file")
glfw_mods :: proc(mods: i32) -> (m: input.Mods) {
    if mods & glfw.MOD_SHIFT != 0 {
        m += {.Shift}
    }
    if mods & glfw.MOD_CONTROL != 0 {
        m += {.Ctrl}
    }
    if mods & glfw.MOD_ALT != 0 {
        m += {.Alt}
    }
    if mods & glfw.MOD_SUPER != 0 {
        m += {.Super}
    }
    return
}

// The wheel callback carries no modifier word, so they are read off the keyboard instead.
@(private = "file")
glfw_mods_now :: proc "c" (w: glfw.WindowHandle) -> (m: input.Mods) {
    held :: proc "c" (w: glfw.WindowHandle, l, r: i32) -> bool {
        return glfw.GetKey(w, l) == glfw.PRESS || glfw.GetKey(w, r) == glfw.PRESS
    }
    if held(w, glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT) {
        m += {.Shift}
    }
    if held(w, glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL) {
        m += {.Ctrl}
    }
    if held(w, glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT) {
        m += {.Alt}
    }
    if held(w, glfw.KEY_LEFT_SUPER, glfw.KEY_RIGHT_SUPER) {
        m += {.Super}
    }
    return
}

// Pixel to cell is a division by the cell size (§8). The pointer arrives in window coordinates
// and the grid is laid out in framebuffer pixels, so the scale between them goes in first.
cell_at :: proc(a: ^App, px, py: f64) -> (x, y: int) {
    fw, fh := glfw.GetFramebufferSize(a.window)
    ww, wh := glfw.GetWindowSize(a.window)
    cw, ch := gfx.painter_cell(&a.painter)
    ox, oy := gfx.painter_origin(&a.painter, fw, fh, a.grid.cols, a.grid.rows)
    sx := ww > 0 ? f64(fw) / f64(ww) : 1
    sy := wh > 0 ? f64(fh) / f64(wh) : 1
    return floor_div(int(px * sx) - ox, cw), floor_div(int(py * sy) - oy, ch)
}

// Truncation toward zero would fold the column left of the grid onto column 0.
@(private = "file")
floor_div :: proc(n, d: int) -> int {
    if d <= 0 {
        return 0
    }
    return n >= 0 ? n / d : -((-n + d - 1) / d)
}

// The other direction, for binds.conf: which position types this glyph. Walked rather than
// tabled, because the layout can change under a running oket and this runs once per config row,
// not once per keystroke.
key_layout_code :: proc(name: string) -> (input.Code, bool) {
    // Refused before input_init rather than answered wrong: the scancode base is part of the
    // mapping, so an early call resolves every letter to a key 8 positions away on X11.
    if name == "" || !input_ready {
        return 0, false
    }
    for sc in 1 ..= 255 {
        code := input.Code(sc) + scancode_shift
        if key_layout_name(code) == name {
            return code, true
        }
    }
    return 0, false
}

// What the position types under the live layout, for display. GLFW only names keys it can see,
// and only in the 0..255 scancode range; a mouse code is never one of them.
key_layout_name :: proc(code: input.Code) -> string {
    sc := c.int(code) - c.int(scancode_shift)
    if sc <= 0 || sc > 255 {
        return ""
    }
    name := glfwb.GetKeyName(glfw.KEY_UNKNOWN, sc)
    return name == nil ? "" : string(name)
}

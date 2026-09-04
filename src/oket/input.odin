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
    glfw.SetWindowFocusCallback(a.window, focus_callback)
    glfw.SetCharCallback(a.window, char_callback)
    glfw.SetMouseButtonCallback(a.window, button_callback)
    glfw.SetCursorPosCallback(a.window, cursor_callback)
    glfw.SetScrollCallback(a.window, scroll_callback)
}

// --- the window's half ---

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || scancode <= 0 {
        return
    }
    code := input.Code(scancode) + scancode_shift
    if input.code_is_modifier(code) {
        return // a held modifier is not a chord; wait for what it qualifies
    }
    // RELEASES NEVER ENTER THE BIND TABLE (PANELS.md §6). One field holds the key that is down,
    // its release clears the field, and an armed picker commits on the way past — so there is
    // no keys-down set, no release axis on bind_find and nothing for describe to grow an arm
    // for.
    if action == glfw.RELEASE {
        if a.held == code {
            a.held = 0
        }
        pick_release(a, code)
        return
    }
    if action != glfw.PRESS && action != glfw.REPEAT {
        return
    }
    if a.held == 0 {
        a.held = code
    }
    // The key that is down QUALIFIES the next one: `tab+enter` is a chord and `tab` on its own
    // still is one, which is why holding it shadows nothing and repeats it instead.
    handle_chord(a, input.Chord{code, glfw_mods(mods), a.held == code ? 0 : a.held},
                 action == glfw.REPEAT)
}

// The window has lost the keyboard, so the release of whatever is down will be delivered
// somewhere else. A `held` nobody clears would qualify every chord after it.
focus_callback :: proc "c" (window: glfw.WindowHandle, focused: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || focused != 0 {
        return
    }
    a.held = 0
    pick_drop(a)
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
    pn, cx, cy := cell_at(a, px, py)
    // Click to focus, before anything reads `active` (PANELS.md §7): the cell counts from the
    // panel it landed in, so aiming the keys somewhere else would place point with one panel's
    // numbers in another panel's document.
    if action == glfw.PRESS {
        panel_focus(a, pn)
    }
    // A document that took the mouse over reads the button itself (§5, §8): a TUI with tracking
    // on wants the press AND the release, and neither is a chord.
    if tm := mouse_events_target(a); tm != nil {
        term_mouse(a, tm, input.MOUSE_BUTTONS[button], cx, cy, glfw_mods(mods),
                   action == glfw.PRESS)
        return
    }
    if action == glfw.PRESS {
        // Only from the lattice the active document was drawn on: a gap and the bar count from
        // the screen, and placing those numbers against a panel's body would move its caret for
        // a click beside it.
        if pn == active_panel(a) {
            // Point first, then the chord (§8): holes fill from point exactly as they do for a
            // key. Unless the row names a verb that places its own — see point_press.
            point_press(a, input.MOUSE_BUTTONS[button], glfw_mods(mods), cx, cy)
            input.mouse_press(&a.mouse, input.MOUSE_BUTTONS[button], cx, cy)
        }
        return
    }
    if m, fired := input.mouse_release(&a.mouse, cx, cy, glfw.GetTime()); fired {
        handle_chord(a, input.Chord{input.mouse_code(m), glfw_mods(mods), 0})
    }
}

// Dragging sweeps the selection; moving free updates what the pointer is offering.
cursor_callback :: proc "c" (window: glfw.WindowHandle, px, py: f64) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil {
        return
    }
    pn, cx, cy := cell_at(a, px, py)
    if tm := mouse_events_target(a); tm != nil {
        term_mouse_at(a, tm, cx, cy, glfw_mods_now(window))
        return
    }
    if input.mouse_motion(&a.mouse, cx, cy) {
        // A drag that leaves the grid it started in counts in another one's cells; the selection
        // holds where it was until the pointer is back.
        if pn == active_panel(a) {
            point_drag(a, cx, cy)
        }
        return
    }
    hover_update(a, pn, cx, cy)
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
    if tm := mouse_events_target(a); tm != nil {
        px, py := glfw.GetCursorPos(window)
        _, cx, cy := cell_at(a, px, py)
        term_mouse(a, tm, wheel, cx, cy, glfw_mods_now(window), true)
        return
    }
    handle_chord(a, input.Chord{input.mouse_code(wheel), glfw_mods_now(window), 0})
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

// The pointer arrives in window coordinates and the grids are laid out in framebuffer pixels,
// so the scale between them goes in first. The division into cells is panel_hit's, because a
// panel has an origin of its own and a column number counts from one grid (§7, §8).
cell_at :: proc(a: ^App, px, py: f64) -> (panel, x, y: int) {
    fw, fh := glfw.GetFramebufferSize(a.window)
    ww, wh := glfw.GetWindowSize(a.window)
    ox, oy := gfx.painter_origin(&a.painter, fw, fh, a.chrome.cols, a.chrome.rows)
    sx := ww > 0 ? f64(fw) / f64(ww) : 1
    sy := wh > 0 ? f64(fh) / f64(wh) : 1
    return panel_hit(a, int(px * sx) - ox, int(py * sy) - oy)
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

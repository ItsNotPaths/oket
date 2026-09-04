package input

// A click is a chord (§8). Mouse codes sit above every keyboard code, so one Code space carries
// both and the bind table, chord_parse and describe grow no mouse arm at all.
//
// The other half of the rule is what the kernel does before dispatching one: a button chord
// moves point to the cell under the pointer, so `<name>` holes fill from point exactly as they
// do for a key. There is one hole-filling path and the mouse is not in it.

Mouse :: enum u16 {
    Click,
    Middle_Click,
    Right_Click,
    Double_Click,
    Wheel_Up,
    Wheel_Down,
    Wheel_Left,
    Wheel_Right,
}

MOUSE_BASE :: Code(1000) // past every X keycode the name table carries

@(rodata)
MOUSE_SPELLING := [Mouse]string {
    .Click        = "click",
    .Middle_Click = "middle-click",
    .Right_Click  = "right-click",
    .Double_Click = "double-click",
    .Wheel_Up     = "wheel-up",
    .Wheel_Down   = "wheel-down",
    .Wheel_Left   = "wheel-left",
    .Wheel_Right  = "wheel-right",
}

// GLFW numbers its buttons left, right, middle.
@(rodata)
MOUSE_BUTTONS := [?]Mouse{.Click, .Right_Click, .Middle_Click}

mouse_code :: proc(m: Mouse) -> Code {
    return MOUSE_BASE + Code(u16(m))
}

code_is_mouse :: proc(c: Code) -> bool {
    return c >= MOUSE_BASE && c < MOUSE_BASE + Code(len(Mouse))
}

// Whether a code is a button at all, for the callers that only need the answer.
mouse_is :: proc(c: Code) -> bool {
    _, yes := mouse_of(c)
    return yes
}

mouse_of :: proc(c: Code) -> (Mouse, bool) {
    if !code_is_mouse(c) {
        return {}, false
    }
    return Mouse(u16(c - MOUSE_BASE)), true
}

mouse_named :: proc(name: string) -> (Code, bool) {
    for spelling, m in MOUSE_SPELLING {
        if spelling == name {
            return mouse_code(m), true
        }
    }
    return 0, false
}

// A wheel step scrolls what is under it and leaves the caret alone; a button chord places the
// caret first. describe says which, because "click moves point" is behaviour a user cannot see
// in the bind row.
mouse_moves_point :: proc(m: Mouse) -> bool {
    #partial switch m {
    case .Wheel_Up, .Wheel_Down, .Wheel_Left, .Wheel_Right:
        return false
    }
    return true
}

// --- press to chord ---

// §14 wants the double-click window in config.conf and describe able to say what it is; this
// is the one place it will be read to.
DOUBLE_CLICK_S :: 0.3

Mouse_Phase :: enum u8 {
    Idle,
    Pressed,
    Dragging,
}

// Cells, not pixels: the window layer divides once and this never learns what a pixel is.
Mouse_State :: struct {
    held:    Mouse,
    phase:   Mouse_Phase,
    at:      [2]int, // where the pointer is
    press:   [2]int, // where the press landed
    last:    [2]int, // where the last click landed
    last_at: f64,
    paired:  bool, // the last click completed a double, so the next one starts over
}

mouse_press :: proc(s: ^Mouse_State, b: Mouse, x, y: int) {
    s.held, s.phase = b, .Pressed
    s.at, s.press = {x, y}, {x, y}
}

// Moving with a button down is a drag: the caller sweeps the selection and the release fires
// nothing.
mouse_motion :: proc(s: ^Mouse_State, x, y: int) -> (drag: bool) {
    s.at = {x, y}
    if s.phase == .Pressed && s.at != s.press {
        s.phase = .Dragging
    }
    return s.phase == .Dragging
}

// The chord the release fires, if any. A second press in the same cell inside the window is a
// double-click; the click after that starts over rather than reading as a third.
mouse_release :: proc(s: ^Mouse_State, x, y: int, now: f64) -> (Mouse, bool) {
    if s.phase == .Idle {
        return {}, false
    }
    b, was_drag := s.held, s.phase == .Dragging
    s.phase = .Idle
    s.at = {x, y}
    if was_drag {
        return {}, false
    }
    double := b == .Click && !s.paired && s.last == s.at && now - s.last_at <= DOUBLE_CLICK_S
    s.last, s.last_at, s.paired = s.at, now, double
    return double ? .Double_Click : b, true
}

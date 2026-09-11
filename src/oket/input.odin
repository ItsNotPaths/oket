package main

import "core:c"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import "../gfx"
import "../input"

// SDL events in, one command out. No chords are written here: this normalizes the scancode or
// the button, asks the bind table, and runs what it names. Every keystroke and every click
// arrives through the one funnel, which is what makes macros and replay cheap later.

// SDL's scancode range; a code past it is a mouse code or garbage.
@(private = "file")
SCANCODE_COUNT :: 512

// Set by input_init. A layout spelling cannot be resolved before it, and answering anyway is
// worse than refusing: see key_layout_code.
input_ready: bool

input_init :: proc(a: ^App) {
    input_ready = true
    // Text arrives only where it was asked for (§8): this is the ask, and the door the IME
    // work walks in through later. The harness has no window to ask for and needs only the
    // keymap the line above stands for (§6).
    if a.window != nil {
        _ = sdl.StartTextInput(a.window)
    }
}

// The frame's events, drained in one place. `wait` parks until the first one arrives — a key,
// a click, a resize, or a session's reader pushing a wake.
input_pump :: proc(a: ^App, wait: bool) {
    ev: sdl.Event
    if wait {
        if !sdl.WaitEvent(&ev) {
            return
        }
        input_event(a, &ev)
    }
    for sdl.PollEvent(&ev) {
        input_event(a, &ev)
    }
}

@(private = "file")
input_event :: proc(a: ^App, ev: ^sdl.Event) {
    #partial switch ev.type {
    case .QUIT, .WINDOW_CLOSE_REQUESTED:
        a.quit = true
    case .KEY_DOWN, .KEY_UP:
        key_event(a, &ev.key)
    case .TEXT_INPUT:
        // Text is not keys (§8): a rune arrives on its own channel, so a bind never sees an
        // `a` on its way into a document and a document never has to guess which it was.
        for r in string(ev.text.text) {
            text_input(a, r)
        }
    case .TEXT_EDITING:
        preedit_set(a, string(ev.edit.text))
    case .WINDOW_FOCUS_LOST:
        // The window has lost the keyboard, so the release of whatever is down will be
        // delivered somewhere else. A `held` nobody clears would qualify every chord after it.
        a.held = 0
        pick_drop(a)
        switcher_drop(a) // alt's release will be delivered elsewhere, so the column ends here
        preedit_set(a, "") // and the composition went with the keyboard
    case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
        button_event(a, &ev.button)
    case .MOUSE_MOTION:
        motion_event(a, &ev.motion)
    case .MOUSE_WHEEL:
        wheel_event(a, &ev.wheel)
    }
}

@(private = "file")
key_event :: proc(a: ^App, ev: ^sdl.KeyboardEvent) {
    code := input.Code(ev.scancode)
    if code == 0 {
        return
    }
    if input.code_is_modifier(code) {
        switcher_hold(a, code, ev.down)
        return // a held modifier is not a chord; wait for what it qualifies
    }
    // A repeat whose up is already in the queue arrived after the hand came off the key: SDL queues
    // the last due repeats behind their own release. The move is stale.
    if ev.repeat && up_queued(ev.scancode) {
        return
    }
    // Releases never enter the bind table.
    if !ev.down {
        if a.held == code {
            a.held = 0
        }
        pick_release(a, code)
        return
    }
    // A key that is down QUALIFIES the next one only if SOMETHING BINDS IT AS A QUALIFIER.
    // `tab` holds because rows hold it; two arrows overlapping is one hand moving fast, and a
    // `left+right` nobody wrote would resolve to nothing and eat the keystroke.
    if a.held == 0 && input.bind_holds(a.binds[:], code) {
        a.held = code
    }
    // `tab+enter` is a chord and `tab` on its own still is one, which is why holding it shadows
    // nothing and repeats it instead.
    handle_chord(a, input.Chord{code, mods_of(ev.mod), a.held == code ? 0 : a.held}, ev.repeat)
}

// A click is a chord, and it fires on RELEASE so a drag cancels it (§8).
@(private = "file")
button_event :: proc(a: ^App, ev: ^sdl.MouseButtonEvent) {
    b := int(ev.button) - 1
    if b < 0 || b >= len(input.MOUSE_BUTTONS) {
        return
    }
    pn, cx, cy := cell_at(a, f64(ev.x), f64(ev.y))
    // The menu is over the panels and is asked before them (MENU.md §6): what it takes never
    // reaches the panel under it.
    if menu_took_button(a, pn, cx, cy, ev.down) {
        return
    }
    // Click to focus, before anything reads `active` (PANELS.md §7): the cell counts from the
    // panel it landed in, so aiming the keys somewhere else would place point with one panel's
    // numbers in another panel's document.
    if ev.down {
        panel_focus(a, pn)
    }
    // A document that took the mouse over reads the button itself (§5, §8): a TUI with tracking
    // on wants the press AND the release, and neither is a chord.
    if tm := mouse_events_target(a); tm != nil {
        term_mouse(a, tm, input.MOUSE_BUTTONS[b], cx, cy, mods_now(), ev.down)
        return
    }
    if ev.down {
        // Only from the lattice the active document was drawn on: a gap and the bar count from
        // the screen, and placing those numbers against a panel's body would move its caret for
        // a click beside it.
        if pn == active_panel(a) {
            // Point first, then the chord (§8): holes fill from point exactly as they do for a
            // key. Unless the row names a verb that places its own — see point_press.
            point_press(a, input.MOUSE_BUTTONS[b], mods_now(), cx, cy)
            input.mouse_press(&a.mouse, input.MOUSE_BUTTONS[b], cx, cy)
        }
        return
    }
    if m, fired := input.mouse_release(&a.mouse, cx, cy, f64(sdl.GetTicks()) / 1000,
                                       f64(a.config.double_ms) / 1000); fired {
        handle_chord(a, input.Chord{input.mouse_code(m), mods_now(), 0})
    }
}

// Dragging sweeps the selection; moving free updates what the pointer is offering.
@(private = "file")
motion_event :: proc(a: ^App, ev: ^sdl.MouseMotionEvent) {
    pn, cx, cy := cell_at(a, f64(ev.x), f64(ev.y))
    if pn == PANEL_MENU {
        menu_hover(a, pn, cx, cy)
        hover_update(a, pn, cx, cy) // over the menu is over no document: whatever was lit goes out
        return
    }
    if tm := mouse_events_target(a); tm != nil {
        term_mouse_at(a, tm, cx, cy, mods_now())
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

@(private = "file")
wheel_event :: proc(a: ^App, ev: ^sdl.MouseWheelEvent) {
    xoff, yoff := f64(ev.x), f64(ev.y)
    if ev.direction == .FLIPPED {
        xoff, yoff = -xoff, -yoff
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
    pn, cx, cy := cell_at(a, f64(ev.mouse_x), f64(ev.mouse_y))
    if pn == PANEL_MENU {
        return // the wheel over a menu is the menu's, and it scrolls with its own keys
    }
    if tm := mouse_events_target(a); tm != nil {
        term_mouse(a, tm, wheel, cx, cy, mods_now(), true)
        return
    }
    handle_chord(a, input.Chord{input.mouse_code(wheel), mods_now(), 0})
}

@(private = "file")
mods_of :: proc(mod: sdl.Keymod) -> (m: input.Mods) {
    if mod & sdl.KMOD_SHIFT != {} {
        m += {.Shift}
    }
    if mod & sdl.KMOD_CTRL != {} {
        m += {.Ctrl}
    }
    if mod & sdl.KMOD_ALT != {} {
        m += {.Alt}
    }
    if mod & sdl.KMOD_GUI != {} {
        m += {.Super}
    }
    return
}

// Mouse events carry no modifier word, so they are read off the keyboard state instead.
@(private = "file")
mods_now :: proc() -> input.Mods {
    return mods_of(sdl.GetModState())
}

// The uncommitted composition, drawn as a ghost by the view pipeline (IME.md §8). The commit
// arrives as TEXT_INPUT like any typed text, so nothing else changes hands.
preedit_set :: proc(a: ^App, text: string) {
    if a.preedit == text {
        return
    }
    delete(a.preedit)
    a.preedit = text != "" ? strings.clone(text) : ""
    views_dirty(a) // the ghost is view state, and the rev is the key it rides
}

// The caret's cell, handed to SDL once per change: the candidate window docks at the caret
// instead of a screen corner (IME.md §8).
ime_area_update :: proc(a: ^App) {
    fw, fh, ww, wh: c.int
    sdl.GetWindowSizeInPixels(a.window, &fw, &fh)
    sdl.GetWindowSize(a.window, &ww, &wh)
    px, py, on := caret_px(a, fw, fh)
    if !on {
        return
    }
    cw, ch := gfx.painter_cell(&a.painter)
    // Framebuffer pixels back to window coordinates: the inverse of cell_at's scale.
    sx := fw > 0 ? f64(ww) / f64(fw) : 1
    sy := fh > 0 ? f64(wh) / f64(fh) : 1
    r := sdl.Rect{i32(f64(px) * sx), i32(f64(py) * sy),
                  i32(f64(cw) * sx + 1), i32(f64(ch) * sy + 1)}
    if r == a.ime_area {
        return
    }
    a.ime_area = r
    _ = sdl.SetTextInputArea(a.window, &r, 0)
}

// The pointer arrives in window coordinates and the grids are laid out in framebuffer pixels,
// so the scale between them goes in first. The division into cells is panel_hit's, because a
// panel has an origin of its own and a column number counts from one grid (§7, §8).
cell_at :: proc(a: ^App, px, py: f64) -> (panel, x, y: int) {
    fw, fh, ww, wh: c.int
    sdl.GetWindowSizeInPixels(a.window, &fw, &fh)
    sdl.GetWindowSize(a.window, &ww, &wh)
    ox, oy := gfx.painter_origin(&a.painter, fw, fh, a.ground.cols, a.ground.rows)
    sx := ww > 0 ? f64(fw) / f64(ww) : 1
    sy := wh > 0 ? f64(fh) / f64(wh) : 1
    return panel_hit(a, int(px * sx) - ox, int(py * sy) - oy)
}

// The other direction, for binds.conf: which position types this glyph. Walked rather than
// tabled, because the layout can change under a running oket and this runs once per config row,
// not once per keystroke.
key_layout_code :: proc(name: string) -> (input.Code, bool) {
    // Refused before input_init rather than answered wrong: SDL's keymap is not up before its
    // window system is.
    if name == "" || !input_ready {
        return 0, false
    }
    for sc in 1 ..< SCANCODE_COUNT {
        if key_layout_name(input.Code(sc)) == name {
            return input.Code(sc), true
        }
    }
    return 0, false
}

// PEEK, not drain: the rest of the batch is wanted, whatever it is.
@(private = "file")
up_queued :: proc(sc: sdl.Scancode) -> bool {
    ups: [16]sdl.Event
    n := max(0, sdl.PeepEvents(&ups[0], len(ups), .PEEKEVENT, .KEY_UP, .KEY_UP))
    for &e in ups[:n] {
        if e.key.scancode == sc {
            return true
        }
    }
    return false
}

// What the position types under the live layout, for display. A key that types nothing — or a
// space, which no chord can be read from — answers "", so key_spelling falls back to the label
// ("space") — the menubar's own key (MENU.md §5). A mouse code is out of range by design.
key_layout_name :: proc(code: input.Code) -> string {
    if code == 0 || code >= SCANCODE_COUNT {
        return ""
    }
    key := u32(sdl.GetKeyFromScancode(sdl.Scancode(code), sdl.KMOD_NONE, false))
    // A printable keycode IS its unshifted codepoint; everything else is flagged or a control.
    if key <= ' ' || key == 0x7f || key >= u32(sdl.K_EXTENDED_MASK) {
        return ""
    }
    buf, n := utf8.encode_rune(rune(key))
    return strings.clone(string(buf[:n]), context.temp_allocator)
}

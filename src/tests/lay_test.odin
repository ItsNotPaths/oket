package tests

import "core:testing"
import "../lay"

// CHROME.md §2.1's rule, as a test: the frame is ONE layouter, and this file builds a tree from
// a struct literal and never reaches for an App. Every rect the chrome has comes out of `solve`,
// so what is asserted here is what six hand-computed sites used to each answer differently.

@(private = "file")
WINDOW :: lay.Rect{0, 0, 100, 40}

// A window's worth of frame: a menubar row off the top, the command line's row off the bottom,
// and the strip taking everything left. Four boxes, and it is the whole of §2.1's table.
@(private = "file")
frame :: proc(menu_rows, cell_h: f32) -> [4]lay.Box {
    return {
        {parent = -1, dir = .Col},
        {parent = 0, size = lay.px(menu_rows * cell_h)},
        {parent = 0, size = lay.grow(), dir = .Row},
        {parent = 0, size = lay.px(cell_h)},
    }
}

@(test)
the_frame_is_a_column_of_three :: proc(t: ^testing.T) {
    boxes := frame(1, 10)
    lay.solve(boxes[:], WINDOW)
    testing.expect_value(t, boxes[1].rect, lay.Rect{0, 0, 100, 10}) // the menubar's row
    testing.expect_value(t, boxes[2].rect, lay.Rect{0, 10, 100, 20}) // the strip, what is left
    testing.expect_value(t, boxes[3].rect, lay.Rect{0, 30, 100, 10}) // the bar's row
}

// A hidden menubar costs the panels nothing, and it is a zero and not a branch: opening it
// reflows a document, and closing it puts every row back where it was (MENU.md §4).
@(test)
a_hidden_menubar_is_a_box_of_no_rows :: proc(t: ^testing.T) {
    boxes := frame(0, 10)
    lay.solve(boxes[:], WINDOW)
    testing.expect_value(t, boxes[1].rect.h, f32(0))
    testing.expect_value(t, boxes[2].rect, lay.Rect{0, 0, 100, 30})
}

// A strip of one is the whole view, gap or no gap: one panel is a length and not a special
// case (PANELS.md §5).
@(test)
a_row_of_one_takes_the_gap_nowhere :: proc(t: ^testing.T) {
    boxes := [?]lay.Box {
        {parent = -1, dir = .Row, gap = 10},
        {parent = 0, size = lay.share(1)},
    }
    lay.solve(boxes[:], WINDOW)
    testing.expect_value(t, boxes[1].rect, lay.Rect{0, 0, 100, 40})
}

// Two halves are worth one full: the slots tile the row exactly, the gap comes out of the two
// that meet at it, half each, and neither end is inset.
@(test)
a_gap_comes_out_of_the_two_boxes_that_meet_at_it :: proc(t: ^testing.T) {
    boxes := [?]lay.Box {
        {parent = -1, dir = .Row, gap = 10},
        {parent = 0, size = lay.share(0.5)},
        {parent = 0, size = lay.share(0.5)},
    }
    lay.solve(boxes[:], WINDOW)
    a, b := boxes[1].rect, boxes[2].rect
    testing.expect_value(t, a, lay.Rect{0, 0, 45, 40})
    testing.expect_value(t, b, lay.Rect{55, 0, 45, 40})
    testing.expect_value(t, b.x - (a.x + a.w), f32(10)) // one gap, and it is the whole of it
}

// Three panels at half the view each is a strip you SCROLL, so the shares overflow rather than
// shrink. A solver that made them fit would have quietly redefined `:width 50`.
@(test)
shares_past_one_overflow_and_do_not_shrink :: proc(t: ^testing.T) {
    boxes := [?]lay.Box {
        {parent = -1, dir = .Row},
        {parent = 0, size = lay.share(0.5)},
        {parent = 0, size = lay.share(0.5)},
        {parent = 0, size = lay.share(0.5)},
    }
    lay.solve(boxes[:], WINDOW)
    testing.expect_value(t, boxes[1].rect.w, f32(50))
    testing.expect_value(t, boxes[3].rect, lay.Rect{100, 0, 50, 40})
}

// What grow divides is what the pixels and the shares LEFT, so a fixed row beside a share is
// not a share of a share.
@(test)
grow_divides_what_is_left_by_weight :: proc(t: ^testing.T) {
    boxes := [?]lay.Box {
        {parent = -1, dir = .Row},
        {parent = 0, size = lay.px(20)},
        {parent = 0, size = lay.grow(1)},
        {parent = 0, size = lay.grow(3)},
    }
    lay.solve(boxes[:], WINDOW)
    testing.expect_value(t, boxes[2].rect, lay.Rect{20, 0, 20, 40})
    testing.expect_value(t, boxes[3].rect, lay.Rect{40, 0, 60, 40})
}

// Padding is where a border rides, so a child starts inside its parent's bevel and no caller
// adds one to the other.
@(test)
padding_insets_what_the_children_get :: proc(t: ^testing.T) {
    boxes := [?]lay.Box {
        {parent = -1, dir = .Col, pad = lay.all(2)},
        {parent = 0, size = lay.grow()},
    }
    lay.solve(boxes[:], WINDOW)
    testing.expect_value(t, boxes[1].rect, lay.Rect{2, 2, 96, 36})
}

// Three deep, which is as deep as chrome goes: the menubar's row, a menu's box, its popout.
// A parent is always earlier in the array, so one forward pass answers all of it.
@(test)
a_parent_is_solved_before_its_children :: proc(t: ^testing.T) {
    boxes := [?]lay.Box {
        {parent = -1, dir = .Col},
        {parent = 0, size = lay.px(20), dir = .Row},
        {parent = 1, size = lay.share(0.5), dir = .Col},
        {parent = 2, size = lay.px(5)},
    }
    lay.solve(boxes[:], WINDOW)
    testing.expect_value(t, boxes[2].rect, lay.Rect{0, 0, 50, 20})
    testing.expect_value(t, boxes[3].rect, lay.Rect{0, 0, 50, 5})
}

// Which box a pixel is over, deepest first: the answer a click needs before a column number
// means anything (PANELS.md §7).
@(test)
a_hit_answers_the_deepest_box :: proc(t: ^testing.T) {
    boxes := [?]lay.Box {
        {parent = -1, dir = .Col},
        {parent = 0, size = lay.px(20), dir = .Row},
        {parent = 1, size = lay.share(0.5)},
    }
    lay.solve(boxes[:], WINDOW)
    testing.expect_value(t, lay.hit(boxes[:], 10, 5), 2) // inside the menu, not just the row
    testing.expect_value(t, lay.hit(boxes[:], 80, 5), 1) // the row, past the menu
    testing.expect_value(t, lay.hit(boxes[:], 10, 30), -1) // below both
}

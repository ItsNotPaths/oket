package lay

// The chrome's layouter (CHROME.md §2.1). Boxes in, rects out. Nothing here knows what a
// document, a panel or the ring is, and its test builds a tree from a struct literal with no
// fixture — the check src/strip and src/menu already hold.
//
// It is a FLEX ROW OR COLUMN and deliberately no more. Chrome is eight kinds of box, three
// deep, none of them wrapping and every one of them monospace (§7). So there is no text flow
// here, no float, no absolute position and no cross-axis alignment: a child always stretches
// across its parent. What a box does not say is the parent's.
//
// The tree is an ARRAY and a parent is always EARLIER in it. That one invariant is what makes
// the whole solve a forward loop with no stack and no recursion.

Dir :: enum u8 {
    Row,
    Col,
}

// How a box is sized ALONG ITS PARENT'S AXIS. Across it, a box is its parent's content.
Fit :: enum u8 {
    Px, // exactly this many pixels
    // A fraction of the parent's content. Shares may sum PAST ONE: that is a strip you scroll,
    // not an error, and nothing here shrinks to make them fit (PANELS.md §5).
    Share,
    Grow, // this weight of whatever the pixels and the shares left over
}

Size :: struct {
    fit: Fit,
    v:   f32,
}

px :: proc(v: f32) -> Size {return {.Px, v}}
share :: proc(v: f32) -> Size {return {.Share, v}}
grow :: proc(v: f32 = 1) -> Size {return {.Grow, v}}

Edges :: struct {
    l, t, r, b: f32,
}

all :: proc(v: f32) -> Edges {return {v, v, v, v}}

Rect :: struct {
    x, y, w, h: f32,
}

Box :: struct {
    parent: int, // -1 for the root, and always EARLIER in the array
    dir:    Dir, // how its CHILDREN lay out; a leaf's is unread
    size:   Size, // along the PARENT's axis
    gap:    f32, // between its children, taken half off each side of the edge they meet at
    // Inside the box, and where a border rides: the solve only ever wants the inset, and a
    // bevel drawn one pixel in is a bevel the content already stepped over.
    pad:    Edges,
    rect:   Rect, // the answer, filled by `solve`
}

// Every box's rectangle, from the window in. ONE FORWARD PASS: a parent's rect is final before
// any child of it is reached, because a parent is earlier in the array.
solve :: proc(boxes: []Box, window: Rect) {
    for &b in boxes {
        if b.parent < 0 {
            b.rect = window
        }
    }
    for i in 0 ..< len(boxes) {
        children(boxes, i)
    }
}

// What a box has left for its children: itself, less its padding.
content :: proc(b: Box) -> Rect {
    return {
        b.rect.x + b.pad.l,
        b.rect.y + b.pad.t,
        max(b.rect.w - b.pad.l - b.pad.r, 0),
        max(b.rect.h - b.pad.t - b.pad.b, 0),
    }
}

inside :: proc(r: Rect, x, y: f32) -> bool {
    return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

// The deepest box a pixel lands in, -1 for none. Later wins at equal depth, which is the order
// they draw in, so the box on top is the box the pointer is over.
hit :: proc(boxes: []Box, x, y: f32) -> int {
    found := -1
    for b, i in boxes {
        if b.parent >= 0 && inside(b.rect, x, y) {
            found = i
        }
    }
    return found
}

// One parent's children, laid along its axis. The scan is over the whole array twice, because a
// dozen boxes read in order beat a child list somebody has to keep valid.
@(private = "file")
children :: proc(boxes: []Box, at: int) {
    p := boxes[at]
    inner := content(p)
    room := p.dir == .Row ? inner.w : inner.h

    // What the pixels and the shares take, so `grow` divides what is left and nothing else.
    n, taken, weight := 0, f32(0), f32(0)
    for b in boxes {
        if b.parent != at {
            continue
        }
        n += 1
        switch b.size.fit {
        case .Px:
            taken += b.size.v
        case .Share:
            taken += b.size.v * room
        case .Grow:
            weight += b.size.v
        }
    }
    if n == 0 {
        return
    }
    spare := max(room - taken, 0)

    // A GAP COMES OUT OF THE TWO BOXES THAT MEET AT IT, half each (PANELS.md §5). The ends stay
    // flush, two halves are still worth one whole, and a row of one has no gap in it at all.
    seen, along := 0, f32(0)
    for &b in boxes {
        if b.parent != at {
            continue
        }
        size: f32
        switch b.size.fit {
        case .Px:
            size = b.size.v
        case .Share:
            size = b.size.v * room
        case .Grow:
            size = weight > 0 ? spare * b.size.v / weight : 0
        }
        lo := seen > 0 ? p.gap / 2 : 0
        hi := seen < n - 1 ? p.gap / 2 : 0
        b.rect = place(p.dir, inner, along + lo, max(size - lo - hi, 0))
        along += size
        seen += 1
    }
}

// A child's rect: `off` and `run` along the parent's axis, the parent's whole content across it.
@(private = "file")
place :: proc(dir: Dir, inner: Rect, off, run: f32) -> Rect {
    if dir == .Row {
        return {inner.x + off, inner.y, run, inner.h}
    }
    return {inner.x, inner.y + off, inner.w, run}
}

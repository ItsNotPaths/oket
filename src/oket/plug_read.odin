package main

import "lues:pt"
import "core:c"
import "lues:abi"
import "core:slice"
import "../desc"
import "../input"
import "../plug"
import "../store"
import "../txt"
import "../view"

// The read half of the seam (§6). lues builds a snapshot's header over the document's own
// arrays; oket hangs its view of the document behind `app` (plug.Side): the descriptor, the
// carets and the folds. Only the descriptor is rebuilt, because desc's own structs carry Odin
// strings and the seam carries pointer plus length.

#assert(size_of(input.Kind) == size_of(abi.Kind))
#assert(size_of(txt.Cursor) == size_of(plug.Cursor))
#assert(size_of(txt.Range) == size_of(plug.Range))

// A Side, plus everything allocated to build it. `side` is FIRST: Snapshot.app casts back.
Side_Box :: struct {
    side: plug.Side,
    dv:   plug.Descriptor,
    d:    ^desc.Descriptor,
    cols: []plug.Column,
    flds: []plug.Field,
    dpth: []c.int32_t,
    curs: []plug.Cursor,
    hid:  []plug.Range,
}

// hooks.side_make. Copies: a held snapshot outlives the call, and the carets and folds move
// with no generation behind them.
side_make :: proc(a: ^App, id: store.Id) -> ^Side_Box {
    return side_fill(a, new(Side_Box), id, nil, nil)
}

// A view stage's input: the text THE KERNEL BUILT for the stage before it (§5), so there is no
// document snapshot to take and the caller owns the bytes for the whole call.
Stage_View :: struct {
    snap: abi.Snapshot,
    box:  ^Side_Box,
}

view_over :: proc(a: ^App, id: store.Id, t: ^pt.Text, gen: u64, dv: ^view.Derived) -> ^Stage_View {
    v := new(Stage_View)
    v.box = side_fill(a, new(Side_Box), id, t, dv)
    v.snap = {
        blocks  = ([^]abi.Block)(raw_data(t.blocks)),
        starts  = ([^]c.ptrdiff_t)(raw_data(t.starts)),
        pieces  = ([^]abi.Piece)(raw_data(t.pieces[:])),
        segs    = ([^]abi.Seg)(raw_data(t.segs[:])),
        nblocks = len(t.blocks),
        nstarts = len(t.starts),
        npieces = len(t.pieces),
        nsegs   = len(t.segs),
        size    = uint(t.size),
        lines   = uint(t.lines),
        gen     = gen,
        doc     = plug_doc(id),
        app     = &v.box.side,
    }
    return v
}

view_free :: proc(v: ^Stage_View) {
    side_free(v.box)
    free(v)
}

side_free :: proc(b: ^Side_Box) {
    if b == nil {
        return
    }
    desc.release(b.d)
    delete(b.cols)
    delete(b.flds)
    delete(b.dpth)
    delete(b.curs)
    delete(b.hid)
    free(b)
}

// Cursors come off the live document: the caret a plugin should read is the one the renderer
// draws (§5). Over a stage's derived text `t`, MAPPED into it, and no folds: that text is
// already derived.
@(private = "file")
side_fill :: proc(a: ^App, b: ^Side_Box, id: store.Id, t: ^pt.Text, dv: ^view.Derived) -> ^Side_Box {
    b.d = store.store_descriptor(a.docs, id)
    primary: uint
    if doc := store.store_doc(a.docs, id); doc != nil {
        primary = uint(doc.primary)
        mapped := slice.clone(doc.cursors[:])
        if t != nil {
            for &c in mapped {
                c.anchor, _ = view.view_pos(dv, t, c.anchor)
                c.head, _ = view.view_pos(dv, t, c.head)
            }
        }
        b.curs = transmute([]plug.Cursor)mapped
    }
    if t == nil {
        b.hid = transmute([]plug.Range)slice.clone(views_hidden(a, id))
    }
    b.side = {
        desc     = view_desc(b),
        cursors  = raw_data(b.curs),
        ncursors = len(b.curs),
        primary  = primary,
        hidden   = raw_data(b.hid),
        nhidden  = len(b.hid),
    }
    return b
}

// --- the world (§12) ---
//
// A view stage has to size what it inserts and cannot ask the pane how wide it is, so the layout
// crosses the seam the way a snapshot does: built, flat, and read as memory. The App itself is
// not what crosses — freezing a layout would be the worse version of that.

Plug_World :: struct {
    world: plug.World, // FIRST, so the pointer a plugin holds casts straight back to this
    panes: []plug.Pane,
}

world_make :: proc(a: ^App) -> ^Plug_World {
    w := new(Plug_World)
    w.panes = make([]plug.Pane, len(a.panels))
    for &p, i in a.panels {
        s := panel_slot(a, &p)
        w.panes[i] = {
            doc     = s != nil ? plug_doc(s.doc) : 0,
            x       = i32(p.body.x),
            y       = i32(p.body.y),
            w       = i32(p.body.w),
            h       = i32(p.body.h),
            top     = s != nil ? i32(s.view.top) : 0,
            focused = b8(i == a.focus),
        }
    }
    w.world = {
        panes  = raw_data(w.panes),
        npanes = len(w.panes),
        // The whole surface in cells: the window floored over the cell (§11).
        cols   = i32(a.win.x / max(a.cell.x, 1)),
        rows   = i32(a.win.y / max(a.cell.y, 1)),
    }
    return w
}

world_free :: proc(w: ^Plug_World) {
    if w == nil {
        return
    }
    delete(w.panes)
    free(w)
}

// The descriptor as the seam spells it. `ctx` is absent on purpose: a kind's context is fixed
// where the kind is registered, so this direction cannot leak one either.
@(private = "file")
view_desc :: proc(v: ^Side_Box) -> ^plug.Descriptor {
    d := v.d
    if d == nil {
        return nil
    }
    v.cols = make([]plug.Column, len(d.columns))
    for c, i in d.columns {
        v.cols[i] = {raw_data(c.name), len(c.name), i32(c.width), c.align, {}}
    }
    v.flds = make([]plug.Field, len(d.fields))
    for f, i in d.fields {
        // "" is the kernel's "no value"; the ABI spells it NULL, so hand exactly that across.
        value := f.value != "" ? raw_data(f.value) : nil
        v.flds[i] = {raw_data(f.name), len(f.name), value, len(f.value),
                     i32(f.line), i32(f.lo), i32(f.hi), {}}
    }
    v.dpth = make([]c.int32_t, len(d.depth))
    for n, i in d.depth {
        v.dpth[i] = i32(n)
    }
    v.dv = {
        file      = raw_data(d.file),
        file_len  = len(d.file),
        columns   = raw_data(v.cols),
        ncolumns  = len(v.cols),
        fields    = raw_data(v.flds),
        nfields   = len(v.flds),
        depth     = raw_data(v.dpth),
        ndepth    = len(v.dpth),
        kind      = abi.Kind(d.kind),
        tab_width = i32(d.tab_width),
        render    = d.render,
        wrap      = d.wrap,
        numbers   = d.numbers,
        selection = d.selection,
        follow    = d.follow,
        input     = d.input,
        mouse     = d.mouse,
        editable  = b8(d.editable),
    }
    return &v.dv
}

// A descriptor a plugin published, as the kernel's own. The KIND decides the context, always:
// a plugin cannot move its documents into another context's keys by publishing one (§5, §7).
// Everything else is the plugin's to say, this being versioned state and not registration.
plug_desc_take :: proc(a: ^App, id: store.Id, p: ^plug.Descriptor) -> ^desc.Descriptor {
    render := p.render
    if render == .Cells {
        // Reserved and not built (descriptor.odin): refused loudly, never silently drawn as
        // something else (§8).
        message_set(a, "render: cells is reserved and not built yet")
        render = .Text
    }
    kind := input.Kind(p.kind)
    if kind == 0 {
        kind = doc_kind(a, id) // "leave it where it is" — the common case for a plain submit
    }
    cols := make([]desc.Column, p.ncolumns, context.temp_allocator)
    for c, i in p.columns[:p.ncolumns] {
        cols[i] = {string(c.name[:c.name_len]), int(c.width), c.align}
    }
    flds := make([]desc.Field, p.nfields, context.temp_allocator)
    for f, i in p.fields[:p.nfields] {
        value := f.value != nil ? string(f.value[:f.value_len]) : ""
        flds[i] = {int(f.line), string(f.name[:f.name_len]), int(f.lo), int(f.hi), value}
    }
    dpth := make([]int, p.ndepth, context.temp_allocator)
    for n, i in p.depth[:p.ndepth] {
        dpth[i] = int(n)
    }
    return desc.new_from(
        {
            render    = render,
            wrap      = p.wrap,
            numbers   = p.numbers,
            ctx       = kind_ctx(a, kind),
            kind      = kind,
            file      = string(p.file[:p.file_len]),
            selection = p.selection,
            follow    = p.follow,
            input     = p.input,
            mouse     = p.mouse,
            editable  = bool(p.editable),
            tab_width = int(p.tab_width),
            columns   = cols,
            fields    = flds,
            depth     = dpth,
        },
    )
}

// `reveal` (§5, §11): a span, and where to put it in the viewport. The kernel owns the
// viewport, so this moves `top` and nothing else — a plugin that wanted to scroll would
// otherwise need a second way to say so.
reveal_span :: proc(a: ^App, id: store.Id, lo, hi: int, at: plug.Reveal) {
    s := ring_of_doc(a, id)
    if s == nil {
        return
    }
    snap := store.store_snapshot(a.docs, id)
    if snap == nil {
        return
    }
    defer pt.snapshot_release(snap)
    // `top` counts lines of the DRAWN document and a reveal names bytes of the one being edited
    // (§6). A span a stage hid maps to the cell the cut left behind, which is §12's answer to
    // "reveal into a fold": scroll to the nearest visible position, and unfolding is a verb the
    // user presses.
    t, dv := views_text(a, id, &snap.text)
    orig := view.original(dv, t)
    from, _ := view.view_pos(dv, t, pt.text_pos(orig, max(lo, 0)))
    to, _ := view.view_pos(dv, t, pt.text_pos(orig, max(hi, lo)))
    first, last := from.line, to.line
    h := max(doc_rect(a, id).h, 1)

    top := s.view.top
    switch at {
    case .Top:
        top = first
    case .Center:
        top = first - h / 2
    case .Nearest:
        if first < top {
            top = first
        } else if last >= top + h {
            top = last - h + 1
        }
    }
    s.view.top = clamp(top, 0, max(pt.text_line_count(t) - 1, 0))
}

// The slot showing a document, if one is. A plugin's document that is not on screen still
// takes writes; it just has no viewport to move.
ring_of_doc :: proc(a: ^App, id: store.Id) -> ^Slot {
    for &l in a.ring.lanes {
        for &s in l.slots {
            if s.live && s.doc == id {
                return &s
            }
        }
    }
    return nil
}

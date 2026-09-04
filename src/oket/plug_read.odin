package main

import "core:c"
import "core:slice"
import "../desc"
import "../plug"
import "../store"
import "../txt"
import "../view"

// The read half of the seam (§6). A plugin reads text, the line index, cursors and the
// descriptor by POINTER, with no lock and no call back into the kernel — so what crosses is a
// header naming the kernel's own arrays, never a copy of the document.
//
// The piece list, the line index and the text blocks are handed over UNCOPIED: their layouts
// are identical on both sides and the asserts below are what keeps that true. Only the
// descriptor's columns and fields are rebuilt, because desc's own structs carry Odin strings
// and the seam carries pointer plus length.

#assert(size_of(txt.Piece) == size_of(plug.Piece))
#assert(size_of(txt.Line_Seg) == size_of(plug.Seg))
#assert(size_of([]u8) == size_of(plug.Block))
#assert(size_of(txt.Cursor) == size_of(plug.Cursor))

// The header, plus everything allocated to build it. `snap` is FIRST, so the pointer a plugin
// holds casts straight back to this.
Plug_View :: struct {
    snap: plug.Snapshot,
    dv:   plug.Descriptor,
    src:  ^txt.Snapshot,
    d:    ^desc.Descriptor,
    cols: []plug.Column,
    flds: []plug.Field,
    dpth: []c.int32_t,
    curs: []plug.Cursor,
}

// One reference to the text and one to the descriptor, taken together so the two name the same
// generation. nil for a document that is not open.
view_make :: proc(a: ^App, id: store.Id) -> ^Plug_View {
    src := store.store_snapshot(&a.docs, id)
    if src == nil {
        return nil
    }
    v := new(Plug_View)
    v.src = src
    view_fill(a, v, id, &src.text, src.gen, nil)
    return v
}

// The same header over text THE KERNEL BUILT rather than a document's own. A view stage past the
// first is handed the stage before it (§5), and that document exists only inside the pipeline —
// so there is no snapshot to hold and the caller owns the bytes for the whole call.
view_over :: proc(
    a: ^App,
    id: store.Id,
    t: ^txt.Text,
    gen: u64,
    dv: ^view.Derived,
) -> ^Plug_View {
    v := new(Plug_View)
    view_fill(a, v, id, t, gen, dv)
    return v
}

@(private = "file")
view_fill :: proc(a: ^App, v: ^Plug_View, id: store.Id, t: ^txt.Text, gen: u64,
                  dv: ^view.Derived) {
    v.d = store.store_descriptor(&a.docs, id)

    // Cursors come off the live document, not the snapshot: the caret a plugin should read is
    // the one the renderer is drawing (§5). MAPPED into the space this call hands over, or a
    // popup positioning itself under the caret lands where the text used to be.
    primary: uint
    if doc := store.store_doc(&a.docs, id); doc != nil {
        curs := slice.clone(doc.cursors[:], context.temp_allocator)
        for &c in curs {
            c.anchor, _ = view.view_pos(dv, t, c.anchor)
            c.head, _ = view.view_pos(dv, t, c.head)
        }
        v.curs = slice.clone(transmute([]plug.Cursor)curs)
        primary = uint(doc.primary)
    }
    v.snap = {
        desc     = view_desc(v),
        blocks   = ([^]plug.Block)(raw_data(t.blocks)),
        starts   = ([^]c.ptrdiff_t)(raw_data(t.starts)),
        pieces   = ([^]plug.Piece)(raw_data(t.pieces[:])),
        segs     = ([^]plug.Seg)(raw_data(t.segs[:])),
        cursors  = raw_data(v.curs),
        nblocks  = len(t.blocks),
        nstarts  = len(t.starts),
        npieces  = len(t.pieces),
        nsegs    = len(t.segs),
        ncursors = len(v.curs),
        primary  = primary,
        size     = uint(t.size),
        lines    = uint(t.lines),
        gen      = gen,
        doc      = plug_doc(id),
    }
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
        cols   = i32(a.chrome.cols),
        rows   = i32(a.chrome.rows),
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

view_free :: proc(v: ^Plug_View) {
    if v == nil {
        return
    }
    if v.src != nil {
        txt.snapshot_release(v.src) // nil for a stage's own input, which nobody refcounts
    }
    desc.release(v.d)
    delete(v.cols)
    delete(v.flds)
    delete(v.dpth)
    delete(v.curs)
    free(v)
}

// The descriptor as the seam spells it. `ctx` is absent on purpose: a kind's context is fixed
// where the kind is registered, so this direction cannot leak one either.
@(private = "file")
view_desc :: proc(v: ^Plug_View) -> ^plug.Descriptor {
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
        kind      = d.kind,
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
    kind := p.kind
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
    snap := store.store_snapshot(&a.docs, id)
    if snap == nil {
        return
    }
    defer txt.snapshot_release(snap)
    // `top` counts lines of the DRAWN document and a reveal names bytes of the one being edited
    // (§6). A span a stage hid maps to the cell the cut left behind, which is §12's answer to
    // "reveal into a fold": scroll to the nearest visible position, and unfolding is a verb the
    // user presses.
    t, dv := views_text(a, id, &snap.text)
    orig := view.original(dv, t)
    from, _ := view.view_pos(dv, t, txt.text_pos(orig, max(lo, 0)))
    to, _ := view.view_pos(dv, t, txt.text_pos(orig, max(hi, lo)))
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
    s.view.top = clamp(top, 0, max(txt.text_line_count(t) - 1, 0))
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

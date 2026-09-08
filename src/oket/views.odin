package main

import "core:mem"
import "core:slice"
import "../gfx"
import "../plug"
import "../store"
import "../txt"
import "../view"

// The view pipeline (VIEWS.md §5, §7), kernel side. A stage is handed the PREVIOUS stage's
// output and returns edits in that space, so a popup that positions itself under the caret is
// right whether or not a fold above it deleted lines.
//
// Four rules the rest of the kernel rests on:
//
//   - NOTHING HERE REACHES THE DOCUMENT. A view edit is never submitted, never journalled and
//     never saved. `store_submit` is untouched, so the platter records original splices and only
//     original splices (§6).
//   - The chain is CONFIG, keyed by kind: `[edit] view = fold, example`. A stage that ran because
//     its plugin was loaded would make load order the layout (§9).
//   - It is built at SETTLE TIME, once, after the drain — not per frame and not per draw. The
//     generation it was built against is the cache key, so a frame that moved nothing rebuilds
//     nothing.
//   - What crosses to the rest of the kernel is three things: the text to draw, one map back to
//     the original, and the list of runs no cell stands for. Motion takes the third and nothing
//     else (§7).

// One document's built view. By pointer, because a stage's text borrows the blocks of the stage
// before it and the arena holding them must not move under a map rehash.
Pipeline :: struct {
    snap:   ^txt.Snapshot, // the original, HELD: every derived text points into its blocks
    text:   txt.Text, // what is drawn
    dv:     view.Derived, // and the map back to the original, every stage folded into one
    hidden: []txt.Range, // §7's export to motion, and the whole of it
    over:   []view.Style, // what the stages painted over their own output
    gen:    u64, // the generation it was built against
    point:  u64, // and the carets, which move without one
    rev:    u64, // the plugin set and the config it was built under
    latch:  bool, // a stage said "not finished, call me again"
    arena:  mem.Dynamic_Arena,
}

// Every open document whose kind names stages, rebuilt where the generation, the config or the
// plugin set moved under the one we have. The return is the latch, which is what stops the frame
// loop idling on work that is half done (§9).
views_settle :: proc(a: ^App) -> (latched: bool) {
    ids := store.store_ids(&a.docs)
    views_prune(a, ids)
    for id in ids {
        names := config_names(&a.config, kind_name(a, doc_kind(a, id)), "view")
        gen, live := store.store_gen(&a.docs, id)
        if len(names) == 0 || !live {
            views_forget(a, id)
            continue
        }
        point := views_point(a, id)
        if p, held := a.views[id];
           held && p.gen == gen && p.point == point && p.rev == a.view_rev && !p.latch {
            continue
        }
        latched |= views_build(a, id, names, gen, point)
    }
    return
}

// The document to DRAW, and the map back to the original. Both nil when no stage had anything to
// say, which is every document until a `view =` line names one — and every consumer then reads
// the original through a nil map, which is the identity (§6).
views_of :: proc(a: ^App, id: store.Id) -> (^txt.Text, ^view.Derived) {
    p, held := a.views[id]
    if !held {
        return nil, nil
    }
    return &p.text, &p.dv
}

// The drawn text, or the caller's own when nothing derived this document. The shape every draw
// site wants, so none of them writes the fallback out again.
views_text :: proc(a: ^App, id: store.Id, t: ^txt.Text) -> (^txt.Text, ^view.Derived) {
    dt, dv := views_of(a, id)
    return dt != nil ? dt : t, dv
}

views_hidden :: proc(a: ^App, id: store.Id) -> []txt.Range {
    p, held := a.views[id]
    return held ? p.hidden : nil
}

views_over :: proc(a: ^App, id: store.Id) -> []view.Style {
    p, held := a.views[id]
    return held ? p.over : nil
}

// A plugin loading, unloading or a config re-read invalidates every chain: the stage list is
// names, and which names resolve has just changed.
views_dirty :: proc(a: ^App) {
    a.view_rev += 1
}

views_forget :: proc(a: ^App, id: store.Id) {
    p, held := a.views[id]
    if !held {
        return
    }
    pipeline_free(p)
    delete_key(&a.views, id)
}

views_destroy :: proc(a: ^App) {
    for _, p in a.views { // not views_forget: deleting from a map while walking it is a bug
        pipeline_free(p)
    }
    delete(a.views)
    a.views = nil
}

@(private = "file")
pipeline_free :: proc(p: ^Pipeline) {
    txt.snapshot_release(p.snap)
    mem.dynamic_arena_destroy(&p.arena)
    free(p)
}

// --- the build ---

// One document, one pass over its stages. The whole chain is thrown away and rebuilt: a stage
// that re-decides everything per keystroke is what §11 warns authors about, and the kernel
// deciding for them would mean holding a stage's output against edits it has not seen.
@(private = "file")
views_build :: proc(a: ^App, id: store.Id, names: []string, gen, point: u64) -> (latched: bool) {
    snap := store.store_snapshot(&a.docs, id)
    if snap == nil {
        return false
    }
    views_forget(a, id)
    p := new(Pipeline)
    mem.dynamic_arena_init(&p.arena)
    al := mem.dynamic_arena_allocator(&p.arena)
    p.snap, p.gen, p.point, p.rev = snap, gen, point, a.view_rev

    t, dv, any := &snap.text, view.Derived{}, false
    runs := make([dynamic]View_Run, 0, 8, al)
    for name in names {
        i, known := plug_view_of(a, name)
        if !known {
            continue
        }
        edits, spans, code, live := view_run(a, i, id, t, gen, any ? &dv : nil, al)
        if !live {
            continue
        }
        p.latch = p.latch || code != 0
        if len(edits) == 0 && len(spans) == 0 {
            continue
        }
        // The stage's own runs are over its OUTPUT, so they are collected AFTER the derive that
        // makes that output, and everything already collected is carried forward through it.
        nt := new(txt.Text, al)
        step: view.Derived
        nt^, step = view.derive(t, edits, al)
        for &r in runs {
            r.lo, _ = view.view_off(&step, r.lo)
            r.hi, _ = view.view_off(&step, r.hi)
        }
        for sp in spans {
            append(&runs, view_run_take(sp, nt.size))
        }
        dv = any ? view.compose(step, dv, al) : step
        t, any = nt, true
    }
    if !any {
        // Nothing folded, nothing inserted: the document IS the drawn one, and a map whose runs
        // are empty would read as "the whole file is hidden".
        pipeline_free(p)
        return false
    }
    p.text, p.dv = t^, dv
    p.hidden = view.hidden(&p.dv, al)
    p.over = view_styles(&p.text, runs[:], al)
    a.views[id] = p
    return p.latch
}

// One stage, through the fault net like every other call into a plugin (§10). What it wrote into
// `out` points at its own memory, so both lists are copied before this returns.
@(private = "file")
view_run :: proc(
    a: ^App,
    i: int,
    id: store.Id,
    t: ^txt.Text,
    gen: u64,
    dv: ^view.Derived,
    alloc: mem.Allocator,
) -> (
    edits: []view.Edit,
    spans: []plug.Span,
    code: i32,
    live: bool,
) {
    v := view_over(a, id, t, gen, dv)
    defer view_free(v)
    out: plug.View_Out
    at := plug.At{doc = plug_doc(id), snap = &v.snap}
    if inst, held := a.insts[id]; held && inst.owner == i {
        at.inst = inst.inst
    }
    r, ok := plug_dispatch(a, i, {what = .View, fn_view = a.plugs[i].viewer, at = &at, out = &out})
    if !ok {
        return nil, nil, 0, false
    }
    own := make([dynamic]view.Edit, 0, out.nedits, alloc)
    last := 0
    for e in out.edits[:out.nedits] {
        // A stage that hands back an overlapping or backwards pair is refused a pair at a time,
        // not a chain at a time: `derive` needs them sorted and disjoint, and half a fold drawn
        // beats the whole document vanishing.
        lo, hi := int(min(e.lo, uint(max(int)))), int(min(e.hi, uint(max(int))))
        if lo < last || hi < lo || lo > t.size {
            continue
        }
        text := e.text_len > 0 ? slice.clone(e.text[:e.text_len], alloc) : nil
        append(&own, view.Edit{lo, min(hi, t.size), text})
        last = hi
    }
    return own[:], slice.clone(out.spans[:out.nspans], context.temp_allocator), r.code, true
}

// A style run a stage published, in the space of what that stage produced. `view.Style` carries
// a line, and these carry offsets until the whole chain has run: a later stage moves them.
@(private = "file")
View_Run :: struct {
    lo, hi: int,
    st:     view.Style,
}

// The token carried through UNRESOLVED, the way a submitted span is (plug.odin): `p.over`
// outlives frames, and a colour written here would sit stale across a theme switch. A channel
// nobody claimed is the theme's, said as its token.
@(private = "file")
view_run_take :: proc(sp: plug.Span, size: int) -> View_Run {
    set := sp.set & {.Fg, .Bg, .Attrs} // untrusted byte: stray bits are not channels
    return {
        lo = clamp(int(min(sp.lo, uint(max(int)))), 0, size),
        hi = clamp(int(min(sp.hi, uint(max(int)))), 0, size),
        st = {
            fg    = .Fg in set ? u32(sp.tok) : u32(gfx.Token.Fg),
            bg    = .Bg in set ? u32(sp.tok) : u32(gfx.Token.Bg),
            attrs = .Attrs in set ? transmute(gfx.Attrs)sp.attrs : {},
        },
    }
}

// The runs, split by line of the drawn document, which is what `view.line_styles` searches. Two
// stages may have painted the same cell, so the sort is stable: the later one drew last and has
// to stay last.
@(private = "file")
view_styles :: proc(
    t: ^txt.Text,
    runs: []View_Run,
    alloc: mem.Allocator,
) -> []view.Style {
    out := make([dynamic]view.Style, 0, len(runs), alloc)
    lines := txt.text_line_count(t)
    for r in runs {
        for line := txt.text_line_at_off(t, r.lo); line < lines; line += 1 {
            lo, hi := txt.text_line_range(t, line)
            if lo >= r.hi {
                break
            }
            st := r.st
            st.line, st.lo, st.hi = line, max(r.lo, lo) - lo, min(r.hi, hi) - lo
            if st.lo < st.hi {
                append(&out, st)
            }
        }
    }
    slice.stable_sort_by(out[:], proc(x, y: view.Style) -> bool {return x.line < y.line})
    return out[:]
}

// --- internals ---

// The carets, as one number. A stage READS them — a popup is positioned by one — and they move
// with no generation behind them, so `gen` alone would leave every stage a keystroke behind.
// FNV over the whole set, not the primary: a stage may read all of them.
@(private = "file")
views_point :: proc(a: ^App, id: store.Id) -> u64 {
    doc := store.store_doc(&a.docs, id)
    if doc == nil {
        return 0
    }
    h := u64(len(doc.cursors))
    for c in doc.cursors {
        for n in ([?]int{c.anchor.line, c.anchor.col, c.head.line, c.head.col}) {
            h = (h ~ u64(n)) * 1099511628211
        }
    }
    return h
}

// A document that closed leaves a chain behind. An Id is a slot plus a seq, so the slot coming
// back as somebody else's document never reads as this one.
@(private = "file")
views_prune :: proc(a: ^App, ids: []store.Id) {
    dead := make([dynamic]store.Id, 0, len(a.views), context.temp_allocator)
    for id in a.views {
        if !slice.contains(ids, id) {
            append(&dead, id)
        }
    }
    for id in dead {
        views_forget(a, id)
    }
}

// The live plugin registered under this name with a stage to run. A name that resolves to
// nothing is skipped in silence: a `view =` line naming a plugin the user has not installed is
// a config file that is ahead of the machine, not an error.
@(private = "file")
plug_view_of :: proc(a: ^App, name: string) -> (int, bool) {
    for p, i in a.plugs {
        if p.live && p.viewer != nil && p.name == name {
            return i, true
        }
    }
    return 0, false
}

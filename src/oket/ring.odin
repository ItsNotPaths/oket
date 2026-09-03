package main

import "core:fmt"
import "../input"
import "../store"
import "../view"

// One ring per KIND (§5), numbered, and `alt+N` addresses slot N of the lane you are looking
// at: three files on alt+1..3, three listings on alt+1..3. A flat ring is the version that
// hides state, because slot 3 could be anything and you have to remember which. Here the
// something it depends on is the FOCUSED PANEL, and the focused panel is drawn as focused
// (PANELS.md §3): the caret is in it and nowhere else, so which lane `alt+N` means is on
// screen and not remembered.
//
// The ring holds the documents; WHERE you are in it is the panel's (PANELS.md §2), because the
// answer differs per panel and everything an instance would duplicate stays here and single.
// The two numberings do not interfere: a ring slot is per kind, stable and keeps its gaps; a
// panel is positional, so closing one renumbers the strip and no document at all.
//
// A slot holds a document and the viewport over it. The viewport is view state (§11): it
// survives a resize, a font change and a reload, so it lives with the slot and not with the
// document.
//
// A ^Slot points into a [dynamic], so nothing holds one across a call that may open a slot.

// N#'s reserved slot (§11): kernel-owned, never closable, and outside the alt+1..9 rotation.
// "Outside the rotation" is a property of the slot, not an exemption a kind asks for.
SLOT_SYSTEM :: -1

Slot :: struct {
    doc:  store.Id,
    view: view.View,
    live: bool, // a closed slot is a GAP: every other slot keeps its number
}

// Slot ids are stable: id = index + 1, and NOTHING renumbers on close. Numbered slots exist
// for muscle memory, and renumbering destroys the one thing they are for.
// `last` and `prev` are two questions one field cannot answer: sharing it makes the lane
// toggle a no-op after every lane round trip.
Lane :: struct {
    kind:  input.Kind,
    slots: [dynamic]Slot,
    last:  int, // where you were when you left this lane; re-entry lands here
    prev:  int, // the slot before the one you are on, inside this lane; alt+shift+` toggles it
}

// A lane INDEX, not a kind: lanes are appended and never removed, so an index is stable.
Spot :: struct {
    lane: int,
    slot: int,
}

Ring :: struct {
    lanes:  [dynamic]Lane,
    system: Slot, // N#; dead until the first thing runs there
}

// The document a slot holds, and the session behind it if it had one. Every close goes through
// here, so a slot cannot drop a PTY on the floor.
doc_close :: proc(a: ^App, id: store.Id) {
    journal_end(a, id) // the work reached its file or was abandoned; either way it is not lost
    plug_inst_close(a, id) // the instance ends where its document does, whoever ended it
    term_close(a, id)
    store.store_close(&a.docs, id)
}

ring_destroy :: proc(a: ^App) {
    for &l in a.ring.lanes {
        for &s in l.slots {
            if s.live {
                doc_close(a, s.doc)
            }
        }
        delete(l.slots)
    }
    if a.ring.system.live {
        doc_close(a, a.ring.system.doc)
    }
    delete(a.ring.lanes)
    a.ring = {}
}

// "1".."N" for a user slot, "#" for the system session. Temp-allocated.
slot_tag :: proc(id: int) -> string {
    return id == SLOT_SYSTEM ? "#" : fmt.tprintf("%d", id)
}

// --- lanes ---

// The lane for a kind, made if this is the kind's first document. Returns an INDEX, because
// appending moves the array and a held pointer would dangle.
lane_index :: proc(r: ^Ring, kind: input.Kind) -> int {
    if i := lane_find(r, kind); i >= 0 {
        return i
    }
    append(&r.lanes, Lane{kind = kind})
    return len(r.lanes) - 1
}

// -1 until the kind has had a document. Callers that only read take this rather than making a
// lane for a kind nothing has used.
lane_find :: proc(r: ^Ring, kind: input.Kind) -> int {
    for l, i in r.lanes {
        if l.kind == kind {
            return i
        }
    }
    return -1
}

// The lane the focused panel is standing in.
lane_current :: proc(a: ^App) -> ^Lane {
    lane := ring_lane(a)
    return lane >= 0 && lane < len(a.ring.lanes) ? &a.ring.lanes[lane] : nil
}

// The lowest live slot of a lane, 0 for a lane holding nothing.
lane_first :: proc(r: ^Ring, lane: int) -> int {
    if lane < 0 || lane >= len(r.lanes) {
        return 0
    }
    for s, i in r.lanes[lane].slots {
        if s.live {
            return i + 1
        }
    }
    return 0
}

// The lane switch itself (§5: switching kinds is its own key, not a walk through the numbers).
// Lands on the slot you last had there, so a lane remembers where you were in it.
ring_lane_goto :: proc(a: ^App, lane: int) -> bool {
    r := &a.ring
    if lane < 0 || lane >= len(r.lanes) || lane == ring_lane(a) {
        return false
    }
    want := r.lanes[lane].last
    if lane_get(r, lane, want) == nil {
        want = lane_first(r, lane)
    }
    return ring_move(a, {lane, want})
}

// --- slots ---

lane_get :: proc(r: ^Ring, lane, id: int) -> ^Slot {
    if id == SLOT_SYSTEM {
        return r.system.live ? &r.system : nil
    }
    if lane < 0 || lane >= len(r.lanes) {
        return nil
    }
    l := &r.lanes[lane]
    if id < 1 || id > len(l.slots) || !l.slots[id - 1].live {
        return nil
    }
    return &l.slots[id - 1]
}

// Where the focused panel is standing, split into the two numbers most callers want one of.
ring_lane :: proc(a: ^App) -> int {
    return panel_focused(a).at.lane
}

ring_slot :: proc(a: ^App) -> int {
    return panel_focused(a).at.slot
}

// Slot `id` of the lane you are in, which is what every alt+N caller means.
ring_get :: proc(a: ^App, id: int) -> ^Slot {
    return lane_get(&a.ring, ring_lane(a), id)
}

ring_focused :: proc(a: ^App) -> ^Slot {
    return panel_slot(a, panel_focused(a))
}

// The lowest free gap OF THE DOCUMENT'S OWN LANE, and the open IS the focus change (§5): so
// opening a file takes you to the text lane whatever you were looking at, and you always see
// where it went.
ring_add :: proc(a: ^App, id: store.Id) -> int {
    lane := lane_index(&a.ring, doc_kind(a, id))
    l := &a.ring.lanes[lane]
    slot := 0
    for &s, i in l.slots {
        if !s.live {
            s = Slot{id, {}, true}
            slot = i + 1
            break
        }
    }
    if slot == 0 {
        append(&l.slots, Slot{id, {}, true})
        slot = len(l.slots)
    }
    ring_move(a, {lane, slot})
    return slot
}

// Aimed placement (§5: the routing target is an argument). The document lands at slot `id` of
// its own lane exactly, growing gaps to reach it, and whatever was there is closed.
ring_put :: proc(a: ^App, id: store.Id, slot: int) {
    if slot < 1 {
        return
    }
    lane := lane_index(&a.ring, doc_kind(a, id))
    l := &a.ring.lanes[lane]
    for len(l.slots) < slot {
        append(&l.slots, Slot{})
    }
    old := &l.slots[slot - 1]
    if old.live {
        doc_close(a, old.doc)
    }
    old^ = Slot{id, {}, true}
    ring_move(a, {lane, slot})
}

// --- moving ---

// The one place focus changes, so the two alternates are recorded in one place too. It moves
// the FOCUSED panel: what `alt+N` addresses is the lane that panel is standing in (§3).
ring_move :: proc(a: ^App, to: Spot) -> bool {
    p := panel_focused(a)
    if lane_get(&a.ring, to.lane, to.slot) == nil || to == p.at {
        return false
    }
    if l := lane_current(a); l != nil {
        l.last = p.at.slot // the lane you are leaving remembers where you were in it
        if to.lane == p.at.lane {
            l.prev = p.at.slot // and a move INSIDE it is what the lane's own toggle undoes
        }
    }
    // A live slot is in at most one panel (§2): the viewport lives on the SLOT, so two panels
    // showing one would fight over it. The panel that had it takes the spot this one is
    // leaving, which is a swap and never a refusal — what `alt+N` promised is that the focused
    // panel's content changes, and it does.
    if other := panel_showing(a, to); other != nil && other != p {
        other.prev, other.at = other.at, p.at
    }
    p.prev, p.at = p.at, to
    return true
}

// alt+`: the most recent spot anywhere. This is vim's ctrl+^ and it carries most switching on
// its own, so it crosses lanes rather than staying inside one.
ring_alt :: proc(a: ^App) {
    ring_move(a, panel_focused(a).prev)
}

// alt+shift+`: the same toggle, kept inside the lane you are in.
ring_alt_lane :: proc(a: ^App) {
    if l := lane_current(a); l != nil {
        ring_move(a, {ring_lane(a), l.prev})
    }
}

// The slot becomes a gap; every other slot keeps its number. Focus falls to the lane's
// alternate when it is live, else its lowest live slot, else out of the lane entirely.
ring_close :: proc(a: ^App, id: int) {
    r := &a.ring
    s := ring_get(a, id)
    if s == nil || id == SLOT_SYSTEM { // N# never closes; its shell is the kernel's
        return
    }
    doc_close(a, s.doc)
    s^ = {}
    p := panel_focused(a)
    l := lane_current(a) // never nil: ring_get proved the panel's lane is in range
    if l.prev == id {
        l.prev = 0
    }
    if l.last == id {
        l.last = 0
    }
    if p.prev.lane == p.at.lane && p.prev.slot == id {
        p.prev = {}
    }
    if p.at.slot != id {
        return
    }
    p.at.slot = 0
    if lane_get(r, p.at.lane, l.prev) != nil {
        p.at.slot, l.prev = l.prev, 0
        return
    }
    if next := lane_first(r, p.at.lane); next != 0 {
        p.at.slot = next
        return
    }
    ring_lane_leave(a) // the lane emptied out, and standing on nothing is not a place
}

// The lane you are in emptied out under you. Fall to the alternate spot, else the first live
// slot anywhere.
ring_lane_leave :: proc(a: ^App) {
    r, p := &a.ring, panel_focused(a)
    p.at.slot = 0
    if lane_get(r, p.prev.lane, p.prev.slot) != nil {
        p.at, p.prev = p.prev, {}
        return
    }
    for lane in 0 ..< len(r.lanes) {
        if first := lane_first(r, lane); first != 0 {
            p.at = {lane, first}
            return
        }
    }
}

// alt+N. An occupied slot is a focus change; an empty one OPENS a fresh instance of the lane
// you are standing in — a document in the text lane, a listing in the files lane. The kernel
// picks nothing: the lane already names the kind (§5).
ring_open :: proc(a: ^App, slot: int) {
    if ring_goto(a, slot) || ring_get(a, slot) != nil {
        return
    }
    l := lane_current(a)
    if l == nil || slot < 1 {
        return
    }
    kind := l.kind // read before ring_put, which may append and move the lanes array
    id, made := kind_fresh(a, kind)
    if !made {
        message_set(a, fmt.tprintf("%d: %s opened nothing", slot, kind_name(a, kind)))
        return
    }
    ring_put(a, id, slot)
}

// alt+N inside the lane you are in, without opening anything.
ring_goto :: proc(a: ^App, slot: int) -> bool {
    return ring_move(a, {ring_lane(a), slot})
}

// Go to a lane, opening its slot 1 when it holds nothing yet: `:ring text` before the first
// file is open should give you a document, not refuse.
ring_lane_enter :: proc(a: ^App, lane: int) -> bool {
    if lane < 0 || lane >= len(a.ring.lanes) {
        return false
    }
    // "Already here" is only an answer while something is focused here: a fresh start's lane 0
    // and a lane just made by name are both an index over nothing.
    if lane == ring_lane(a) && ring_focused(a) != nil {
        return true
    }
    if ring_lane_goto(a, lane) {
        return true
    }
    id, made := kind_fresh(a, a.ring.lanes[lane].kind)
    if !made {
        return false
    }
    ring_put(a, id, 1)
    return true
}

// `:ring <kind>`. The name is resolved against the kind table, so the kernel matches a config
// string against data and never against a literal of its own (§5).
ring_lane_named :: proc(a: ^App, name: string) -> (int, bool) {
    kind, found := kind_named(a, name)
    if !found {
        return 0, false
    }
    return lane_index(&a.ring, kind), true
}

// Go to N#. It is a reserved slot rather than a lane, so this is not a bare ring_goto: that
// only ever addresses the lane you are already in.
ring_show_system :: proc(a: ^App) -> bool {
    if !a.ring.system.live {
        return false
    }
    return ring_move(a, {ring_lane(a), SLOT_SYSTEM})
}

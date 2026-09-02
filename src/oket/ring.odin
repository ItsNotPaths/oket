package main

import "core:fmt"
import "../input"
import "../store"
import "../view"

// One ring per KIND (§5), numbered, and `alt+N` addresses slot N of the lane you are looking
// at: three files on alt+1..3, three listings on alt+1..3. A flat ring is the version that
// hides state, because slot 3 could be anything and you have to remember which. Here the
// something it depends on is the surface filling your screen, which is the least invisible
// state there is.
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
    lanes:   [dynamic]Lane,
    lane:    int, // index into lanes; the one alt+N addresses
    focused: int, // slot id inside that lane; 0 = none
    prev:    Spot, // the most recent spot anywhere; alt+` toggles across lanes
    system:  Slot, // N#; dead until the first thing runs there
}

ring_destroy :: proc(a: ^App) {
    for &l in a.ring.lanes {
        for &s in l.slots {
            if s.live {
                store.store_close(&a.docs, s.doc)
            }
        }
        delete(l.slots)
    }
    if a.ring.system.live {
        store.store_close(&a.docs, a.ring.system.doc)
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

lane_current :: proc(r: ^Ring) -> ^Lane {
    return r.lane >= 0 && r.lane < len(r.lanes) ? &r.lanes[r.lane] : nil
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
ring_lane_goto :: proc(r: ^Ring, lane: int) -> bool {
    if lane < 0 || lane >= len(r.lanes) || lane == r.lane {
        return false
    }
    want := r.lanes[lane].last
    if lane_get(r, lane, want) == nil {
        want = lane_first(r, lane)
    }
    return ring_move(r, {lane, want})
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

// Slot `id` of the lane you are in, which is what every alt+N caller means.
ring_get :: proc(r: ^Ring, id: int) -> ^Slot {
    return lane_get(r, r.lane, id)
}

ring_focused :: proc(r: ^Ring) -> ^Slot {
    return ring_get(r, r.focused)
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
    ring_move(&a.ring, {lane, slot})
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
        store.store_close(&a.docs, old.doc)
    }
    old^ = Slot{id, {}, true}
    ring_move(&a.ring, {lane, slot})
}

// --- moving ---

// The one place focus changes, so the two alternates are recorded in one place too.
ring_move :: proc(r: ^Ring, to: Spot) -> bool {
    if lane_get(r, to.lane, to.slot) == nil {
        return false
    }
    if to.lane == r.lane && to.slot == r.focused {
        return false
    }
    if l := lane_current(r); l != nil {
        l.last = r.focused // the lane you are leaving remembers where you were in it
        if to.lane == r.lane {
            l.prev = r.focused // and a move INSIDE it is what the lane's own toggle undoes
        }
    }
    r.prev = {r.lane, r.focused}
    r.lane, r.focused = to.lane, to.slot
    return true
}

// alt+`: the most recent spot anywhere. This is vim's ctrl+^ and it carries most switching on
// its own, so it crosses lanes rather than staying inside one.
ring_alt :: proc(r: ^Ring) {
    ring_move(r, r.prev)
}

// alt+shift+`: the same toggle, kept inside the lane you are in.
ring_alt_lane :: proc(r: ^Ring) {
    if l := lane_current(r); l != nil {
        ring_move(r, {r.lane, l.prev})
    }
}

// The slot becomes a gap; every other slot keeps its number. Focus falls to the lane's
// alternate when it is live, else its lowest live slot, else out of the lane entirely.
ring_close :: proc(a: ^App, id: int) {
    r := &a.ring
    s := ring_get(r, id)
    if s == nil || id == SLOT_SYSTEM { // N# never closes; its shell is the kernel's
        return
    }
    store.store_close(&a.docs, s.doc)
    s^ = {}
    l := lane_current(r) // never nil: ring_get proved r.lane is in range
    if l.prev == id {
        l.prev = 0
    }
    if l.last == id {
        l.last = 0
    }
    if r.prev.lane == r.lane && r.prev.slot == id {
        r.prev = {}
    }
    if r.focused != id {
        return
    }
    r.focused = 0
    if lane_get(r, r.lane, l.prev) != nil {
        r.focused, l.prev = l.prev, 0
        return
    }
    if next := lane_first(r, r.lane); next != 0 {
        r.focused = next
        return
    }
    ring_lane_leave(r) // the lane emptied out, and standing on nothing is not a place
}

// The lane you are in emptied out under you. Fall to the alternate spot, else the first live
// slot anywhere.
ring_lane_leave :: proc(r: ^Ring) {
    r.focused = 0
    if lane_get(r, r.prev.lane, r.prev.slot) != nil {
        r.lane, r.focused = r.prev.lane, r.prev.slot
        r.prev = {}
        return
    }
    for lane in 0 ..< len(r.lanes) {
        if first := lane_first(r, lane); first != 0 {
            r.lane, r.focused = lane, first
            return
        }
    }
}

// alt+N. An occupied slot is a focus change; an empty one OPENS a fresh instance of the lane
// you are standing in — a document in the text lane, a listing in the files lane. The kernel
// picks nothing: the lane already names the kind (§5).
ring_open :: proc(a: ^App, slot: int) {
    if ring_goto(&a.ring, slot) || ring_get(&a.ring, slot) != nil {
        return
    }
    l := lane_current(&a.ring)
    if l == nil || slot < 1 {
        return
    }
    kind := l.kind // read before ring_put, which may append and move the lanes array
    id, made := kind_fresh(a, kind)
    if !made {
        message_set(a, fmt.tprintf("%d: %s opened nothing", slot, kind_name(kind)))
        return
    }
    ring_put(a, id, slot)
}

// alt+N inside the lane you are in, without opening anything.
ring_goto :: proc(r: ^Ring, slot: int) -> bool {
    return ring_move(r, {r.lane, slot})
}

// Go to a lane, opening its slot 1 when it holds nothing yet: `:ring text` before the first
// file is open should give you a document, not refuse.
ring_lane_enter :: proc(a: ^App, lane: int) -> bool {
    if lane < 0 || lane >= len(a.ring.lanes) {
        return false
    }
    // "Already here" is only an answer while something is focused here: a fresh start's lane 0
    // and a lane just made by name are both an index over nothing.
    if lane == a.ring.lane && ring_focused(&a.ring) != nil {
        return true
    }
    if ring_lane_goto(&a.ring, lane) {
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
    kind, found := kind_named(name)
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
    return ring_move(&a.ring, {a.ring.lane, SLOT_SYSTEM})
}

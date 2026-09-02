package rc

import "core:sync"

// The one refcount txt and desc share. Atomic, because the last release may come from a
// worker thread, not the one that took the reference.

retain :: proc(count: ^int) {
    sync.atomic_add(count, 1)
}

// True when this took the last reference, and only then may the caller free. atomic_sub
// answers the count BEFORE the subtraction, so 1 means ours was the last.
release :: proc(count: ^int) -> bool {
    return sync.atomic_sub(count, 1) == 1
}

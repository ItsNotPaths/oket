package wake

// The host's frame-loop waker, and the only one. A session's reader thread and the I/O worker
// both have to reach a loop parked in a wait that only an event ends, and both sit BELOW the
// host: neither may import it, and neither has any business importing the other. So the hook
// lives here, the host points it at its own event queue ONCE, and a package that starts waiting
// later cannot grow a second hook for the host to forget — which is a completion nobody wakes
// for, and a frame that never comes.
//
// Tests leave it inert and poll instead.
hook := proc() {}

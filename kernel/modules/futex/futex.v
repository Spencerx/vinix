@[has_globals]
module futex

import event
import event.eventstruct
import klock
import errno
import proc
import katomic

__global (
	futex_lock klock.Lock
	futexes    map[u64]&eventstruct.Event
)

pub fn initialise() {
	futexes = map[u64]&eventstruct.Event{}
}

pub fn syscall_futex_wait(_ voidptr, ptr &int, expected int) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: futex_wait(0x%llx, %d)\n', process.name.str, voidptr(ptr),
		expected)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	if katomic.load(ptr) != expected {
		return errno.err, errno.eagain
	}

	mut e := &eventstruct.Event(unsafe { nil })
	phys := proc.current_thread().process.pagemap.virt2phys(u64(ptr)) or {
		return errno.err, errno.get()
	}

	futex_lock.acquire()

	if phys !in futexes {
		e = &eventstruct.Event{}
		futexes[phys] = e
	} else {
		e = unsafe { futexes[phys] } // will always be present
	}

	futex_lock.release()

	mut events := [e]
	defer {
		unsafe { events.free() }
	}
	event.await(mut events, true) or { return errno.err, errno.eintr }

	return 0, 0
}

pub fn syscall_futex_wake(_ voidptr, ptr &int) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: futex_wake(0x%llx)\n', process.name.str, voidptr(ptr))
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	// Ensure this page is not lazily mapped
	katomic.load(ptr)

	phys := proc.current_thread().process.pagemap.virt2phys(u64(ptr)) or {
		return errno.err, errno.get()
	}

	futex_lock.acquire()
	defer {
		futex_lock.release()
	}

	if phys !in futexes {
		return 0, 0
	}

	mut e := unsafe { futexes[phys] }
	ret := event.trigger(mut e, true)

	return ret, 0
}

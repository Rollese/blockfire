class_name VoiceRoutingTable
extends RefCounted
## Lock-free-on-the-hot-path seam between the sim tick (writer) and the voice relay
## thread (reader). The tick builds into the inactive buffer then flips an index under a
## trivial mutex (one int store). The relay thread only read()s. A small reverse-direction
## bind queue carries authenticated (player_id, voice_peer) bindings back to the tick.

var _buffers: Array = [{}, {}]
var _active: int = 0
var _mutex := Mutex.new()
var _bind_queue: Array = []

## tick thread: replace the inactive buffer wholesale, then atomically flip.
## Caller transfers ownership — pass a freshly-built Dictionary each tick and never mutate it
## after publishing (a later mutation would tear a concurrent reader's snapshot).
func publish(table: Dictionary) -> void:
	var inactive := 1 - _active
	_buffers[inactive] = table
	_mutex.lock()
	_active = inactive
	_mutex.unlock()

## voice thread: the latest fully-published snapshot.
func read() -> Dictionary:
	_mutex.lock()
	var idx := _active
	_mutex.unlock()
	return _buffers[idx]

## voice thread: enqueue an authenticated binding for the tick to fold in.
func enqueue_bind(player_id: int, voice_peer: int) -> void:
	_mutex.lock()
	_bind_queue.append([player_id, voice_peer])
	_mutex.unlock()

## tick thread: drain pending bindings (call before building the next publish).
func drain_binds() -> Array:
	_mutex.lock()
	var out := _bind_queue
	_bind_queue = []
	_mutex.unlock()
	return out

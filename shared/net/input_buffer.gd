class_name InputBuffer
extends RefCounted
## Per-client server-side input jitter buffer. INPUT packets carry the last N frames for redundancy
## (see input_command.gd); this buffer dedups frames it has already seen and drains them FIFO
## (oldest -> newest), one per sim tick. An isolated dropped packet is recovered from the redundant
## copy in the next packet, so the server's view of the player no longer stales (rubber-band, bots
## losing track). Depth is bounded by MAX_DEPTH so a burst of recovered frames never adds unbounded
## input latency — past the cap the OLDEST frames are coalesced away (the freshest input wins).

const MAX_DEPTH := 4   # ~133 ms at 30 Hz; absorbs isolated-drop recovery, caps catch-up latency

var _queue: Array = []          # frames ordered oldest -> newest
var _last_enqueued_tick: int = -1   # highest client_tick ever enqueued (for dedup)
var coalesced: int = 0          # frames dropped to honour MAX_DEPTH (telemetry)

## Enqueue every frame newer than anything seen so far (dedup against redundant copies). Frames are
## assumed ordered oldest -> newest within a bundle.
func ingest(frames: Array) -> void:
	for f in frames:
		var t: int = int(f["client_tick"])
		if t <= _last_enqueued_tick:
			continue   # already seen via an earlier packet's redundant copy
		_queue.append(f)
		_last_enqueued_tick = t
	# Bound latency: keep only the newest MAX_DEPTH frames.
	while _queue.size() > MAX_DEPTH:
		_queue.pop_front()
		coalesced += 1

## Remove and return the oldest buffered frame, or null if empty (caller treats null as starvation).
func pop() -> Variant:
	if _queue.is_empty():
		return null
	return _queue.pop_front()

func size() -> int:
	return _queue.size()

extends TestCase
## Per-client server-side input jitter buffer. INPUT packets carry the last N frames (redundancy);
## the buffer dedups already-seen frames and drains them FIFO (oldest -> newest), one per sim tick,
## so an isolated dropped packet is recovered from the next packet's redundant copy. Depth is
## bounded so recovery never adds unbounded latency.

func _frame(tick: int) -> Dictionary:
	return {"client_tick": tick, "move_x": 0.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.0, "buttons": 0, "view_server_tick": 0}

func test_pop_empty_returns_null() -> void:
	var b := InputBuffer.new()
	assert_eq(b.pop(), null, "empty buffer pops null")

func test_drains_fifo_oldest_first() -> void:
	var b := InputBuffer.new()
	b.ingest([_frame(10), _frame(11), _frame(12)])
	assert_eq(b.pop()["client_tick"], 10)
	assert_eq(b.pop()["client_tick"], 11)
	assert_eq(b.pop()["client_tick"], 12)
	assert_eq(b.pop(), null)

func test_ignores_already_seen_frames() -> void:
	# Redundant bundles overlap: re-sending a frame the buffer already enqueued must not duplicate it.
	var b := InputBuffer.new()
	b.ingest([_frame(10), _frame(11)])
	assert_eq(b.pop()["client_tick"], 10)
	b.ingest([_frame(10), _frame(11), _frame(12)])  # 10 & 11 already seen; only 12 is new
	assert_eq(b.pop()["client_tick"], 11)
	assert_eq(b.pop()["client_tick"], 12)
	assert_eq(b.pop(), null)

func test_recovers_dropped_frame_from_redundant_copy() -> void:
	# Packet carrying frame 11 is "lost"; the next packet redundantly re-includes 11 alongside 12.
	var b := InputBuffer.new()
	b.ingest([_frame(10)])
	assert_eq(b.pop()["client_tick"], 10)        # consumed; buffer empty (would starve next tick)
	b.ingest([_frame(11), _frame(12)])           # 11 recovered from the redundant copy
	assert_eq(b.pop()["client_tick"], 11, "dropped frame is recovered, in order")
	assert_eq(b.pop()["client_tick"], 12)

func test_depth_is_bounded_drops_oldest() -> void:
	# A burst of unseen frames beyond MAX_DEPTH keeps only the newest MAX_DEPTH (bounded latency);
	# the dropped oldest are counted as coalesced.
	var b := InputBuffer.new()
	var frames: Array = []
	for t in range(1, InputBuffer.MAX_DEPTH + 4):  # MAX_DEPTH + 3 frames
		frames.append(_frame(t))
	b.ingest(frames)
	assert_eq(b.size(), InputBuffer.MAX_DEPTH, "buffer never exceeds MAX_DEPTH")
	assert_eq(b.coalesced, 3, "the 3 oldest over cap are coalesced")
	# The frames that remain are the NEWEST ones (lowest latency on the freshest input).
	assert_eq(b.pop()["client_tick"], 4)  # frames 1,2,3 dropped; newest MAX_DEPTH kept

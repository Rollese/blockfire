extends TestCase
## Msg.COLLAPSE {building_id:u16} round-trip + the client-side apply path the join-replay relies on
## (A3 ghost-ladder fix: the server re-sends every past collapse to a late joiner, so apply_collapse
## must be safe on a store that never held the building's pieces, and safe to receive twice).

func test_collapse_round_trip() -> void:
	var bytes := Protocol.encode_collapse(4242)
	assert_eq(bytes[0], Protocol.Msg.COLLAPSE, "tagged as COLLAPSE")
	assert_eq(Protocol.decode_collapse(bytes), 4242, "building id round-trips")

func test_apply_collapse_on_unsynced_store_queues_for_renderer() -> void:
	# Late joiner: the collapse replay can arrive BEFORE any STRUCTURE_BASELINE (or the building's
	# pieces simply never sync — the server already removed them). No pieces to drop, but the bid
	# must still reach the renderer queue so the ghost roof ladders get freed on the first frame.
	var wv := WorldView.new()
	var ver := wv.structs_version()
	wv.apply_collapse(7)
	assert_eq(wv.structs_version(), ver, "no pieces dropped -> no version bump (no pool re-walk)")
	assert_eq(wv.take_collapsed(), [7], "collapse queued for the renderer despite an empty store")
	assert_eq(wv.take_collapsed(), [], "queue drains once")

func test_apply_collapse_twice_is_idempotent() -> void:
	# Double delivery (live event + a hypothetical replay overlap) must not corrupt anything —
	# the renderer's _free_ladders_for / _spawn_rubble_for both early-return on unknown ids.
	var wv := WorldView.new()
	wv.apply_collapse(7)
	wv.apply_collapse(7)
	assert_eq(wv.take_collapsed(), [7, 7], "both queue entries harmless (renderer guards on unknown ids)")

func test_apply_collapse_ignores_zero_sentinel() -> void:
	var wv := WorldView.new()
	wv.apply_collapse(0)
	assert_eq(wv.take_collapsed(), [], "0 = loose pieces sentinel, never a collapse target")

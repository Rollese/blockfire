extends TestCase

func test_publish_then_read_returns_latest() -> void:
	var t := VoiceRoutingTable.new()
	t.publish({1: {"team": 0}})
	assert_eq(t.read(), {1: {"team": 0}})
	t.publish({2: {"team": 1}})
	assert_eq(t.read(), {2: {"team": 1}})

func test_prior_snapshot_unaffected_by_next_publish() -> void:
	var t := VoiceRoutingTable.new()
	t.publish({1: {"x": 1}})
	var held := t.read()              # reader holds a reference
	t.publish({9: {"x": 9}})          # writer swaps to the other buffer
	assert_eq(held, {1: {"x": 1}}, "captured snapshot is not mutated by the swap")

func test_bind_queue_drains_once_and_clears() -> void:
	var t := VoiceRoutingTable.new()
	t.enqueue_bind(7, 700)
	t.enqueue_bind(8, 800)
	var binds := t.drain_binds()
	assert_eq(binds.size(), 2)
	assert_eq(binds[0], [7, 700])
	assert_eq(t.drain_binds(), [], "drained queue is empty")

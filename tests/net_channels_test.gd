extends TestCase
## Channel topology invariants. The reliable BULK channel (3) carries dense-map structure traffic on
## its own ENet stream so a baseline flood can't head-of-line-block SELF_STATE on CONTROL (0). ENet
## allocates exactly NetHost.CHANNELS per peer, so every channel index used by a send MUST be < CHANNELS
## (a send on an unallocated channel is dropped/errors) — this test fails loudly if someone adds a
## channel constant without widening the count.

func test_channel_constants_are_distinct() -> void:
	var ids := [NetHost.CHANNEL_CONTROL, NetHost.CHANNEL_SNAPSHOT, NetHost.CHANNEL_INPUT, NetHost.CHANNEL_BULK]
	var seen := {}
	for c in ids:
		assert_false(seen.has(c), "channel index %d is used twice" % c)
		seen[c] = true

func test_all_channels_within_allocated_count() -> void:
	for c in [NetHost.CHANNEL_CONTROL, NetHost.CHANNEL_SNAPSHOT, NetHost.CHANNEL_INPUT, NetHost.CHANNEL_BULK]:
		assert_true(c >= 0 and c < NetHost.CHANNELS,
			"channel %d must be < CHANNELS (%d) — ENet allocates exactly that many per peer" % [c, NetHost.CHANNELS])

func test_bulk_is_separate_from_control() -> void:
	assert_true(NetHost.CHANNEL_BULK != NetHost.CHANNEL_CONTROL,
		"structure BULK must not share the CONTROL channel — that's the head-of-line-blocking split")

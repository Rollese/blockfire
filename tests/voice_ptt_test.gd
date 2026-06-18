extends TestCase

func test_idle_when_no_key() -> void:
	var p := VoicePtt.new()
	assert_eq(p.active_channel(), VoicePtt.NONE)
	assert_false(p.transmitting())

func test_proximity_key_opens_proximity() -> void:
	var p := VoicePtt.new()
	p.set_keys(true, false)
	assert_eq(p.active_channel(), VoicePacket.KIND_PROXIMITY)
	assert_true(p.transmitting())

func test_squad_takes_precedence_when_both_held() -> void:
	var p := VoicePtt.new()
	p.set_keys(true, true)
	assert_eq(p.active_channel(), VoicePacket.KIND_SQUAD, "squad wins so comms never leak to enemies")

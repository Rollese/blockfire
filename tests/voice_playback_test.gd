extends TestCase
## Tests the pure playback decision: bus + spatial flag + mute filter. The actual
## AudioStreamGenerator/decoder is the owner-playtested shell.

func test_proximity_is_spatial_on_voice_bus() -> void:
	var d := VoicePlayback.route(VoicePacket.KIND_PROXIMITY, 5, {})
	assert_eq(d["bus"], "Voice")
	assert_true(d["spatial"], "proximity is positional 3D")
	assert_true(d["play"])

func test_squad_is_2d() -> void:
	var d := VoicePlayback.route(VoicePacket.KIND_SQUAD, 5, {})
	assert_false(d["spatial"], "squad is flat 2D")

func test_muted_speaker_is_dropped() -> void:
	var muted := {5: true}
	assert_false(VoicePlayback.route(VoicePacket.KIND_PROXIMITY, 5, muted)["play"])

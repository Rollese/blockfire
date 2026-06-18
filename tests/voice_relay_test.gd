extends TestCase
## Tests the pure relay DECISION: given an inbound frame + the trusted speaker id + the
## routing table, which recipient peers get the (re-stamped) frame. No sockets/threads.

func _table() -> Dictionary:
	return {
		1: {"pos": Vector3.ZERO, "team": 0, "squad": 1, "voice_peer": 101, "alive": true},
		2: {"pos": Vector3(10, 0, 0), "team": 0, "squad": 1, "voice_peer": 102, "alive": true},
		3: {"pos": Vector3(20, 0, 0), "team": 1, "squad": 2, "voice_peer": 103, "alive": true},
	}

func test_proximity_restamps_speaker_and_targets_in_range() -> void:
	var inbound := VoicePacket.encode(999, VoicePacket.KIND_PROXIMITY, 4, PackedByteArray([7]))
	var plan := VoiceRelay.process_frame(1, inbound, _table(), 50.0, 12)  # trusted speaker = 1
	assert_eq(plan["recipients"], [102, 103], "nearest-first peers, enemy included")
	var d := VoicePacket.decode(plan["frame"])
	assert_eq(d["speaker_id"], 1, "client-supplied 999 overwritten with trusted id")
	assert_eq(d["seq"], 4, "seq preserved")

func test_valid_frame_with_no_recipients_is_still_restamped() -> void:
	# Trusted speaker 99 is absent from the table → recipients_for returns [].
	# Unlike the malformed case, a VALID inbound frame is still re-stamped.
	var inbound := VoicePacket.encode(999, VoicePacket.KIND_PROXIMITY, 8, PackedByteArray([7]))
	var plan := VoiceRelay.process_frame(99, inbound, _table(), 50.0, 12)
	assert_eq(plan["recipients"], [], "speaker not in table → no recipients")
	assert_true(plan["frame"].size() > 0, "valid frame is still re-stamped, not emptied")
	var d := VoicePacket.decode(plan["frame"])
	assert_eq(d["speaker_id"], 99, "frame re-stamped with trusted speaker id")

func test_malformed_frame_yields_no_recipients() -> void:
	var plan := VoiceRelay.process_frame(1, PackedByteArray([1, 2]), _table(), 50.0, 12)
	assert_eq(plan["recipients"], [])
	assert_eq(plan["frame"], PackedByteArray())

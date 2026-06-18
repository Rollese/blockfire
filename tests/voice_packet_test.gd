extends TestCase

func test_round_trip() -> void:
	var frame := PackedByteArray([1, 2, 3, 4, 5])
	var bytes := VoicePacket.encode(77, VoicePacket.KIND_PROXIMITY, 1234, frame)
	var d := VoicePacket.decode(bytes)
	assert_eq(d["speaker_id"], 77)
	assert_eq(d["kind"], VoicePacket.KIND_PROXIMITY)
	assert_eq(d["seq"], 1234)
	assert_eq(d["frame"], frame)

func test_squad_kind_round_trips() -> void:
	var d := VoicePacket.decode(VoicePacket.encode(9, VoicePacket.KIND_SQUAD, 0, PackedByteArray([9])))
	assert_eq(d["kind"], VoicePacket.KIND_SQUAD)

func test_rejects_bad_kind() -> void:
	var b := VoicePacket.encode(1, 7, 0, PackedByteArray([1]))   # 7 is not a valid kind
	assert_eq(VoicePacket.decode(b), {}, "unknown kind decodes to empty")

func test_rejects_truncated() -> void:
	assert_eq(VoicePacket.decode(PackedByteArray([1, 2, 3])), {}, "short buffer rejected")

func test_rejects_oversized_frame_length() -> void:
	# claim a frame longer than the payload actually present
	var buf := StreamPeerBuffer.new()
	buf.put_u16(1); buf.put_u8(0); buf.put_u16(0); buf.put_u16(999); buf.put_u8(1)
	assert_eq(VoicePacket.decode(buf.data_array), {}, "len/payload mismatch rejected")

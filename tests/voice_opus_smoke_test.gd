extends TestCase
## Smoke: the GDExtension classes load and a frame round-trips through the engine boundary.
## Skips cleanly if the native lib is not built (CI/dev without Rust), so the suite stays green.

func test_opus_extension_round_trip() -> void:
	if not ClassDB.class_exists("OpusVoiceEncoder"):
		assert_true(true, "voice_opus extension not built — smoke skipped")
		return
	var enc = ClassDB.instantiate("OpusVoiceEncoder")
	var dec = ClassDB.instantiate("OpusVoiceDecoder")
	var n: int = dec.frame_samples()
	var pcm := PackedFloat32Array()
	pcm.resize(n)
	for i in range(n):
		pcm[i] = sin(float(i) * 0.05) * 0.5
	var frame: PackedByteArray = enc.encode(pcm)
	assert_true(frame.size() > 0 and frame.size() <= 256, "encoded frame is non-empty + bounded")
	var out: PackedFloat32Array = dec.decode(frame)
	assert_eq(out.size(), n, "decoded a full frame of samples")

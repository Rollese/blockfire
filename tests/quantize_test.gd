extends TestCase

func test_position_round_trip_mm() -> void:
	for v in [0.0, 1.234, -56.789, 499.999]:
		var enc := Quantize.enc_pos(v)
		assert_almost_eq(Quantize.dec_pos(enc), v, 0.001, "pos %s" % v)

func test_angle_round_trip() -> void:
	for a in [0.0, PI * 0.5, PI, PI * 1.999]:
		var enc := Quantize.enc_angle(a)
		assert_true(enc >= 0 and enc <= 0xFFFF, "u16 range")
		assert_almost_eq(Quantize.dec_angle(enc), a, 0.001, "angle %s" % a)

func test_angle_wraps_negative() -> void:
	var d := Quantize.dec_angle(Quantize.enc_angle(-0.1))
	assert_true(d >= 0.0 and d < TAU, "wrapped into range, got %s" % d)

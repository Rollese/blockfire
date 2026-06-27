extends TestCase
## SmokeCloud (M7): opacity envelope for a deployed smoke grenade cloud — grows in, holds, fades out.
## Pure so the curve is frame-timing-independent and unit-checkable; the renderer scales puff alpha by it.

func test_before_birth_and_after_expiry_are_clear() -> void:
	assert_almost_eq(SmokeCloud.envelope(-0.5, 5.0), 0.0, 0.001, "no smoke before it deploys")
	assert_almost_eq(SmokeCloud.envelope(5.0, 5.0), 0.0, 0.001, "fully gone at expiry")
	assert_almost_eq(SmokeCloud.envelope(7.0, 5.0), 0.0, 0.001, "stays gone after expiry")

func test_grows_in_from_zero() -> void:
	var half := SmokeCloud.envelope(SmokeCloud.GROW * 0.5, 5.0)
	assert_almost_eq(half, 0.5, 0.02, "halfway through the grow-in the cloud is ~half opacity")

func test_full_opacity_during_hold() -> void:
	assert_almost_eq(SmokeCloud.envelope(2.5, 5.0), 1.0, 0.001, "fully opaque mid-life")

func test_fades_out_before_expiry() -> void:
	# At `FADE/2` before expiry the cloud is ~half faded.
	var t := 5.0 - SmokeCloud.FADE * 0.5
	assert_almost_eq(SmokeCloud.envelope(t, 5.0), 0.5, 0.02, "halfway through the fade-out is ~half opacity")

func test_envelope_is_bounded() -> void:
	for i in range(60):
		var age := float(i) * 0.1
		var e := SmokeCloud.envelope(age, 5.0)
		assert_true(e >= 0.0 and e <= 1.0, "envelope stays within [0,1]")

func test_short_duration_never_exceeds_one() -> void:
	# A duration shorter than grow+fade still produces a valid (sub-unity) bump, never >1 or <0.
	for i in range(12):
		var age := float(i) * 0.1
		var e := SmokeCloud.envelope(age, 1.0)
		assert_true(e >= 0.0 and e <= 1.0, "short-lived smoke envelope stays in [0,1]")
	assert_almost_eq(SmokeCloud.envelope(0.0, 1.0), 0.0, 0.001, "still clear at birth")
	assert_almost_eq(SmokeCloud.envelope(1.0, 1.0), 0.0, 0.001, "still clear at expiry")

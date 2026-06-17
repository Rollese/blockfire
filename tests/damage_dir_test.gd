extends TestCase

func test_bearing_points_from_victim_toward_source() -> void:
	# source due +X of victim -> world bearing atan2(dx,dz) = +90 deg.
	var b := DamageDir.bearing(Vector3(0,0,0), Vector3(10,0,0))
	assert_almost_eq(rad_to_deg(b), 90.0, 1.0)

func test_bearing_behind_is_180() -> void:
	var b := DamageDir.bearing(Vector3(0,0,0), Vector3(0,0,-10))
	assert_almost_eq(absf(rad_to_deg(b)), 180.0, 1.0)

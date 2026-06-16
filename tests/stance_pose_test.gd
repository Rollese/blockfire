extends TestCase

func test_prone_is_shorter_than_stand() -> void:
	var stand := StancePose.of(Stance.STAND, Stance.LEAN_NONE, false, false)
	var prone := StancePose.of(Stance.PRONE, Stance.LEAN_NONE, false, false)
	assert_true(prone["height"] < stand["height"], "prone capsule is shorter")

func test_lean_applies_tilt_sign() -> void:
	var l := StancePose.of(Stance.STAND, Stance.LEAN_LEFT, false, false)
	var r := StancePose.of(Stance.STAND, Stance.LEAN_RIGHT, false, false)
	assert_true(l["tilt"] > 0.0 and r["tilt"] < 0.0, "lean tilts opposite directions")

func test_downed_is_prone_height() -> void:
	var d := StancePose.of(Stance.STAND, Stance.LEAN_NONE, true, false)
	var prone := StancePose.of(Stance.PRONE, Stance.LEAN_NONE, false, false)
	assert_almost_eq(d["height"], prone["height"], 0.01, "downed renders prone")

extends TestCase

func test_prone_is_shorter_than_stand() -> void:
	var stand := StancePose.of(Stance.STAND, Stance.LEAN_NONE, false, false)
	var prone := StancePose.of(Stance.PRONE, Stance.LEAN_NONE, false, false)
	assert_true(prone["height"] < stand["height"], "prone capsule is shorter")

func test_lean_applies_tilt_sign() -> void:
	var l := StancePose.of(Stance.STAND, Stance.LEAN_LEFT, false, false)
	var r := StancePose.of(Stance.STAND, Stance.LEAN_RIGHT, false, false)
	assert_true(l["tilt"] > 0.0 and r["tilt"] < 0.0, "lean tilts opposite directions")

func test_camera_lean_shifts_and_rolls_opposite_directions() -> void:
	# Local first-person camera lean: leaning must peek the eye laterally (matching the server's
	# LEAN_OFFSET shot-origin shift) and roll the view, in opposite directions for left vs right.
	var none := StancePose.camera_lean(Stance.LEAN_NONE)
	assert_almost_eq(none["lat"], 0.0, 0.001, "no lean -> no lateral shift")
	assert_almost_eq(none["roll"], 0.0, 0.001, "no lean -> no roll")
	var l := StancePose.camera_lean(Stance.LEAN_LEFT)
	var r := StancePose.camera_lean(Stance.LEAN_RIGHT)
	assert_true(l["lat"] < 0.0 and r["lat"] > 0.0, "left peeks the eye left, right peeks right")
	assert_true(signf(l["roll"]) != signf(r["roll"]), "lean rolls the view opposite ways")
	assert_almost_eq(absf(l["lat"]), Stance.LEAN_OFFSET, 0.001, "lateral peek matches the server shot-origin offset")

func test_downed_is_prone_height() -> void:
	var d := StancePose.of(Stance.STAND, Stance.LEAN_NONE, true, false)
	var prone := StancePose.of(Stance.PRONE, Stance.LEAN_NONE, false, false)
	assert_almost_eq(d["height"], prone["height"], 0.01, "downed renders prone")

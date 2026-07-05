extends TestCase
## M5.5-P3: pure melee geometry — reach, rear-arc back-stab, nearest-frontal target selection.

func test_in_reach() -> void:
	assert_true(Melee.in_reach(Vector3.ZERO, Vector3(0, 0, 2.0)))    # 2.0m < 2.2m reach
	assert_false(Melee.in_reach(Vector3.ZERO, Vector3(0, 0, 3.0)))

func test_is_backstab_from_behind() -> void:
	# Target faces +z (yaw 0). Attacker behind it (rel points to the target's back) = back-stab.
	assert_true(Melee.is_backstab(0.0, Vector3(0, 0, -1.0)))
	# Attacker in front (+z) = not a back-stab.
	assert_false(Melee.is_backstab(0.0, Vector3(0, 0, 1.0)))

func test_is_backstab_respects_arc() -> void:
	# Directly to the target's side (90 deg off directly-behind) is outside the rear arc.
	assert_false(Melee.is_backstab(0.0, Vector3(1.0, 0, 0.0)))

func test_is_backstab_forgives_offset_from_directly_behind() -> void:
	# A2 playtest: sneaking behind a strafing/turning target rarely lands within 30 deg of dead-centre
	# behind. The rear arc must forgive a clearly-behind hit ~50 deg off directly-behind (instant kill),
	# while a near-perpendicular ~80 deg hit stays a front hit.
	var behind_50 := Vector3(sin(deg_to_rad(50.0)), 0.0, -cos(deg_to_rad(50.0)))
	var behind_80 := Vector3(sin(deg_to_rad(80.0)), 0.0, -cos(deg_to_rad(80.0)))
	assert_true(Melee.is_backstab(0.0, behind_50))
	assert_false(Melee.is_backstab(0.0, behind_80))

func test_best_target_picks_nearest_in_front() -> void:
	var atk := {"pos": Vector3.ZERO, "yaw": 0.0, "team": 0}
	var enemies := [
		{"id": 5, "pos": Vector3(0, 0, 1.2), "team": 1},
		{"id": 6, "pos": Vector3(0, 0, 0.8), "team": 1},
	]
	assert_eq(Melee.best_target(atk, enemies), 6)   # nearest within reach
	assert_eq(Melee.best_target(atk, [{"id": 9, "pos": Vector3(0, 0, 5.0), "team": 1}]), 0)  # none in reach

func test_best_target_ignores_friendlies_and_behind() -> void:
	var atk := {"pos": Vector3.ZERO, "yaw": 0.0, "team": 0}
	# Friendly in reach (same team) -> ignored; enemy behind -> ignored.
	assert_eq(Melee.best_target(atk, [{"id": 5, "pos": Vector3(0, 0, 1.0), "team": 0}]), 0)
	assert_eq(Melee.best_target(atk, [{"id": 7, "pos": Vector3(0, 0, -1.0), "team": 1}]), 0)

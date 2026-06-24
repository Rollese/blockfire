extends TestCase
## M5.5-P3: pure melee geometry — reach, rear-arc back-stab, nearest-frontal target selection.

func test_in_reach() -> void:
	assert_true(Melee.in_reach(Vector3.ZERO, Vector3(0, 0, 1.0)))    # 1.0m < 1.5m
	assert_false(Melee.in_reach(Vector3.ZERO, Vector3(0, 0, 3.0)))

func test_is_backstab_from_behind() -> void:
	# Target faces +z (yaw 0). Attacker behind it (rel points to the target's back) = back-stab.
	assert_true(Melee.is_backstab(0.0, Vector3(0, 0, -1.0)))
	# Attacker in front (+z) = not a back-stab.
	assert_false(Melee.is_backstab(0.0, Vector3(0, 0, 1.0)))

func test_is_backstab_respects_arc() -> void:
	# Directly to the target's side is outside the 60-degree rear arc.
	assert_false(Melee.is_backstab(0.0, Vector3(1.0, 0, 0.0)))

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

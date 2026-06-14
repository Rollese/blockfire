extends TestCase

const Bot := preload("res://bots/bot_driver.gd")

const A := Vector3(-600, 0, -400)
const B := Vector3(-300, 0, 300)
const C := Vector3(0, 0, 0)
const D := Vector3(300, 0, -300)
const E := Vector3(600, 0, 400)

func test_prefers_central_non_owned_over_closer_corner() -> void:
	# Bot sits next to corner A, but center C is non-owned -> must pick C.
	var idx := Bot.choose_objective_index([A, C], [-1, -1], 0, Vector3(-590, 0, -390), Vector3.ZERO)
	assert_eq(idx, 1, "central point chosen over the nearer corner")

func test_skips_points_team_owns() -> void:
	# Team 0 owns C; only E is capturable.
	var idx := Bot.choose_objective_index([C, E], [0, -1], 0, Vector3.ZERO, Vector3.ZERO)
	assert_eq(idx, 1, "owned central point skipped")

func test_defends_nearest_when_team_owns_all() -> void:
	var idx := Bot.choose_objective_index([A, C], [0, 0], 0, Vector3(-590, 0, -390), Vector3.ZERO)
	assert_eq(idx, 0, "owns all -> defend nearest to bot (A)")

func test_tie_break_by_distance_from_bot() -> void:
	# B and D are equidistant from center; bot near B -> pick B.
	var idx := Bot.choose_objective_index([B, D], [-1, -1], 0, Vector3(-280, 0, 280), Vector3.ZERO)
	assert_eq(idx, 0, "equal center distance -> nearer-to-bot wins")

func test_empty_points_returns_negative_one() -> void:
	assert_eq(Bot.choose_objective_index([], [], 0, Vector3.ZERO, Vector3.ZERO), -1)

func test_owners_shorter_than_points_defaults_neutral() -> void:
	# No match-state yet (owners empty) -> all treated capturable, central wins.
	var idx := Bot.choose_objective_index([A, C], [], 0, Vector3(-590, 0, -390), Vector3.ZERO)
	assert_eq(idx, 1, "missing owners default to neutral/capturable")

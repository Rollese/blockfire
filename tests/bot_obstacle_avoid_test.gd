extends TestCase
## Bot building/wall avoidance: when a marching bot is stuck against a structure (not a slope), it
## should sidestep toward the CLEARER side of the nearby building cells and slide around it, instead
## of the terrain-slope sidestep's blind always-left shuffle into a corner. Pure helpers only
## (headless-safe, AGENTS.md §10) — the reactive wiring lives in BotDriver._update_slope_avoid.
const BotDriver := preload("res://bots/bot_driver.gd")
const BuildGrid := preload("res://shared/sim/build_grid.gd")

func test_sidesteps_away_from_a_wall_on_the_left() -> void:
	# Marching +Z; a wall of cells sits on the -X (left) side. Escape must go +X (right).
	var obstacles: Array = [Vector3(-2.4, 0, 0), Vector3(-2.4, 0, 2.4), Vector3(-2.4, 0, -2.4)]
	var dir := BotDriver.obstacle_sidestep(Vector3.ZERO, Vector3(0, 0, 1), obstacles)
	assert_true(dir.x > 0.3, "steers toward the open +X side, away from the -X wall (got %s)" % dir)

func test_sidesteps_away_from_a_wall_on_the_right() -> void:
	var obstacles: Array = [Vector3(2.4, 0, 0), Vector3(2.4, 0, 2.4), Vector3(2.4, 0, -2.4)]
	var dir := BotDriver.obstacle_sidestep(Vector3.ZERO, Vector3(0, 0, 1), obstacles)
	assert_true(dir.x < -0.3, "steers toward the open -X side, away from the +X wall (got %s)" % dir)

func test_sidestep_is_lateral_not_pure_retreat() -> void:
	# A flush wall dead ahead: both sides equally clear -> deterministic lateral escape (not straight back).
	var dir := BotDriver.obstacle_sidestep(Vector3.ZERO, Vector3(0, 0, 1), [])
	assert_true(absf(dir.x) > 0.5, "escape has a strong lateral component, so the bot rounds the wall (got %s)" % dir)

func test_zero_heading_is_a_noop() -> void:
	var dir := BotDriver.obstacle_sidestep(Vector3.ZERO, Vector3.ZERO, [Vector3(1, 0, 0)])
	assert_eq(dir, Vector3.ZERO, "no heading -> nothing to sidestep")

func test_nearby_obstacle_cells_filters_by_range_and_floor() -> void:
	var structs := {
		1: {"cell": Vector3i(-1, 0, 0)},   # ~1.2 m away, same floor -> kept
		2: {"cell": Vector3i(-1, 0, 1)},   # near, same floor -> kept
		3: {"cell": Vector3i(12, 0, 0)},   # ~29 m away -> dropped (out of scan radius)
		4: {"cell": Vector3i(-1, 3, 0)},   # 7.2 m up (different floor) -> dropped
	}
	var cells := BotDriver.nearby_obstacle_cells(structs, Vector3.ZERO)
	assert_eq(cells.size(), 2, "keeps only same-floor cells within scan radius")
	for c in cells:
		assert_true(absf((c as Vector3).y) < 3.0, "kept cells are on the walking floor")

func test_stuck_reuses_slope_displacement_check() -> void:
	# Obstacle avoidance triggers on the same commanded-vs-actual stall the slope system uses.
	assert_true(BotDriver.is_slope_stuck(Vector3(3, 0, 0).length(), 0.1), "wall-clipped (~0 travel) -> stuck")
	assert_false(BotDriver.is_slope_stuck(3.0, 2.8), "moving freely -> not stuck")

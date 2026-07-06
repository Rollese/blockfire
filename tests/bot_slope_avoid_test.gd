extends TestCase
const BotDriver := preload("res://bots/bot_driver.gd")
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# Cliff rising along +x; shallow along z.
func _cliff() -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 41; g.rows = 41; g.spacing = 2.0; g.origin_x = -40.0; g.origin_z = -40.0
	var s := PackedFloat32Array(); s.resize(1681)
	for zi in 41:
		for xi in 41:
			var wx := -40.0 + float(xi) * 2.0
			s[zi*41 + xi] = maxf(0.0, wx) * 4.0   # steep up +x, flat/downhill -x
	g.samples = s
	return g

func test_stuck_detection_true_when_clipped() -> void:
	assert_true(BotDriver.is_slope_stuck(Vector3(3,0,0).length(), Vector3(0.1,0,0).length()), "clipped ~0 -> stuck")
	assert_false(BotDriver.is_slope_stuck(3.0, 2.8), "moved freely -> not stuck")

func test_sidestep_picks_shallower_perpendicular() -> void:
	var g := _cliff()
	var new_dir := BotDriver.slope_sidestep(g, Vector3(0,0,0), Vector3(1,0,0))
	assert_true(Terrain.slope_at(g, new_dir.x * 2.0, new_dir.z * 2.0) <= Terrain.MAX_WALKABLE_SLOPE_DEG,
		"sidestep heading points somewhere walkable")
	assert_true(absf(new_dir.z) > 0.5, "steers laterally (along the ridge), not straight into the cliff")

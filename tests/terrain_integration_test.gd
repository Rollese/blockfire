extends TestCase
const Pawn := preload("res://shared/sim/pawn.gd")
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")
const MapDef := preload("res://shared/sim/map_def.gd")

# End-to-end: the tool-regenerated proving_grounds heightmap loads and reads back its sculpted
# features (valley basin, cliff mesa, flat base pad). Guards the M15 map + fleet gate.
func test_proving_grounds_terrain_features() -> void:
	var m := MapDef.load_file("res://maps/conquest_proving_grounds.json")
	assert_ne(m, null, "map loads")
	var g := Terrain.load_for_map(m, "res://maps", Callable())
	assert_ne(g, null, "proving_grounds has terrain")
	assert_true(Terrain.height_at(g, -300, 300) < -2.0, "valley basin is below grade")
	assert_true(Terrain.height_at(g, 415, 0) > 15.0, "the too-steep ridge crest is high")
	assert_true(Terrain.slope_at(g, 410, 0) > Terrain.MAX_WALKABLE_SLOPE_DEG, "ridge face is unwalkable (slope-block test)")
	# base pad is FLAT (low slope) at its LOCAL grade — not forced to y=0 (that made bases sit in pits).
	assert_true(Terrain.slope_at(g, -900, 0) < 6.0, "team-0 base pad is flat (low slope), got %.1f deg" % Terrain.slope_at(g, -900, 0))
	# Regression guard for the fleet-freeze bug: the base pad must be walkable ALL the way out (no
	# ring of >50 deg pad-edge slope). Sample a full circle at the old hard-pad radius.
	for deg in range(0, 360, 30):
		var rad := deg_to_rad(float(deg))
		var x := -900.0 + cos(rad) * 45.0
		var z := 0.0 + sin(rad) * 45.0
		assert_true(Terrain.slope_at(g, x, z) <= Terrain.MAX_WALKABLE_SLOPE_DEG,
			"base-0 pad edge walkable at %d deg (slope %.1f)" % [deg, Terrain.slope_at(g, x, z)])

# Regression (review C1/I1): a pawn must be able to descend INTO sub-zero terrain (a valley) —
# the platform_floor 0.0 default used to clamp it back up to y=0 and it floated over the basin.
func test_pawn_descends_into_sub_zero_valley() -> void:
	var g := _basin(-10.0)   # a bowl dipping to -10 m
	var loop := SimLoop.new()
	loop.terrain = g
	var p := Pawn.new(1)
	p.pos = Vector3(0, 2, 0)
	loop.world.pawns[1] = p
	for i in 120:
		loop.step({1: {}}, 100.0)
	assert_almost_eq(p.pos.y, -10.0, 0.1, "pawn settles on the valley floor at -10 m, not clamped to y=0")

# Regression (review I1): walking off a ledge DOWN INTO a valley must clear grounded so a landing
# edge (fall damage) can fire and there's no free mid-air jump. The old maxf(floor_y,0.0) masked it.
func test_grounded_clears_falling_below_zero() -> void:
	var g := _basin(-12.0)
	var loop := SimLoop.new()
	loop.terrain = g
	var p := Pawn.new(1)
	p.pos = Vector3(0, -3, 0)     # a few metres above the -12 valley floor, at rest
	p.grounded = true
	loop.world.pawns[1] = p
	loop.step({1: {}}, 100.0)     # one tick of gravity: now falling below y=0
	assert_false(p.grounded, "airborne over a sub-zero valley clears grounded (no free jump, fall damage arms)")

# A bowl: flat 0 at the rim, dipping smoothly to `depth` (negative) at the centre over a 20x20 grid.
func _basin(depth: float) -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 41; g.rows = 41; g.spacing = 2.0; g.origin_x = -40.0; g.origin_z = -40.0
	var s := PackedFloat32Array(); s.resize(1681)
	for zi in 41:
		for xi in 41:
			var wx := -40.0 + float(xi) * 2.0
			var wz := -40.0 + float(zi) * 2.0
			var d := sqrt(wx*wx + wz*wz)
			s[zi*41 + xi] = depth * clampf(1.0 - d / 40.0, 0.0, 1.0)   # depth at centre -> 0 at r>=40
	g.samples = s
	return g

# Flat grid at a raised height of `h` m across a 40x40 m area.
func _plateau(h: float) -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 21; g.rows = 21; g.spacing = 2.0; g.origin_x = -20.0; g.origin_z = -20.0
	var s := PackedFloat32Array(); s.resize(441); s.fill(h)
	g.samples = s
	return g

func test_pawn_rests_on_raised_terrain() -> void:
	var p := Pawn.new(1)
	p.terrain = _plateau(5.0)
	p.pos = Vector3(0, 8, 0)   # dropped in above the plateau
	for i in 60:
		p.step(1.0/30.0, {}, 100.0)
	assert_almost_eq(p.pos.y, 5.0, 0.05, "pawn settles on the 5 m plateau, not y=0")
	assert_true(p.grounded, "grounded on terrain")

func test_pawn_flat_when_no_terrain() -> void:
	var p := Pawn.new(1)   # terrain null
	p.pos = Vector3(0, 8, 0)
	for i in 60:
		p.step(1.0/30.0, {}, 100.0)
	assert_almost_eq(p.pos.y, 0.0, 0.01, "no terrain -> flat y=0 (unchanged behaviour)")

func test_downed_pawn_rests_on_terrain() -> void:
	var p := Pawn.new(1)
	p.terrain = _plateau(3.0)
	p.is_downed = true
	p.pos = Vector3(0, 6, 0)
	for i in 60:
		p.step(1.0/30.0, {}, 100.0)
	assert_almost_eq(p.pos.y, 3.0, 0.05, "downed pawn crawls on terrain surface")

const SimLoop := preload("res://shared/sim/sim_loop.gd")

func test_sim_loop_folds_terrain_into_floor() -> void:
	var loop := SimLoop.new()
	loop.terrain = _plateau(4.0)
	var p := Pawn.new(1)
	p.pos = Vector3(0, 7, 0)
	loop.world.pawns[1] = p
	for i in 90:
		loop.step({1: {}}, 100.0)
	assert_almost_eq(p.pos.y, 4.0, 0.05, "SimLoop rests the pawn on the plateau via the floor chain")

func test_sim_loop_slope_blocks_horizontal_advance() -> void:
	# A wall-steep ramp: 0 m at x=-20 rising ~4 m per cell (way past MAX_WALKABLE_SLOPE_DEG).
	var g := TerrainGrid.new()
	g.cols = 21; g.rows = 21; g.spacing = 2.0; g.origin_x = -20.0; g.origin_z = -20.0
	var s := PackedFloat32Array(); s.resize(441)
	for zi in 21:
		for xi in 21:
			s[zi*21 + xi] = maxf(0.0, float(xi) * 4.0)
	g.samples = s
	var loop := SimLoop.new()
	loop.terrain = g
	var p := Pawn.new(1)
	p.pos = Vector3(-10, 0, 0)
	loop.world.pawns[1] = p
	var start_x := p.pos.x
	for i in 30:
		loop.step({1: {"move_x": 1.0, "move_y": 0.0}}, 100.0)   # drive +x into the cliff
	assert_true(p.pos.x < start_x + 8.0, "slope clips the advance up the cliff (did not run up it freely)")

const Vehicle := preload("res://shared/sim/vehicle.gd")

func _transport(pos: Vector3) -> Vehicle:
	var def := {"max_hp":600,"max_speed":20.0,"reverse_speed":6.0,"accel":10.0,"drag":8.0,
		"turn_rate":1.5,"respawn_ticks":450,"turret_offset":[0,1,0],"exit_offset":[2,0,0],
		"seats":[{"role":"driver","offset":[0,0,0]}]}
	return Vehicle.make(Vehicle.id_for(0), 0, def, 0, pos)

func test_vehicle_rests_on_terrain() -> void:
	var loop := SimLoop.new()
	loop.terrain = _plateau(3.0)
	var v := _transport(Vector3(0, 6, 0))
	loop.world.vehicles[v.id] = v
	for i in 90:
		loop.step_vehicles({v.id: {}}, 100.0)
	assert_almost_eq(v.pos.y, 3.0, 0.1, "vehicle settles on the plateau, not y=0")

func test_vehicle_cannot_climb_cliff() -> void:
	var g := TerrainGrid.new()
	g.cols = 21; g.rows = 21; g.spacing = 2.0; g.origin_x = -20.0; g.origin_z = -20.0
	var s := PackedFloat32Array(); s.resize(441)
	for zi in 21:
		for xi in 21:
			s[zi*21 + xi] = maxf(0.0, float(xi) * 4.0)
	g.samples = s
	var loop := SimLoop.new()
	loop.terrain = g
	var v := _transport(Vector3(-10, 0, 0))
	v.heading = PI / 2.0   # face +x (forward = sin,cos -> +x at heading pi/2)
	loop.world.vehicles[v.id] = v
	var start_x := v.pos.x
	for i in 60:
		loop.step_vehicles({v.id: {"move_y": 1.0, "move_x": 0.0}}, 100.0)
	assert_true(v.pos.x < start_x + 10.0, "cliff blocks the drive-up")

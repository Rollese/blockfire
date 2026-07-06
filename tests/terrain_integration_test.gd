extends TestCase
const Pawn := preload("res://shared/sim/pawn.gd")
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

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

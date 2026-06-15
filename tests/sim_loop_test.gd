extends TestCase

func test_step_advances_pawns_from_inputs() -> void:
	var sim := SimLoop.new()
	sim.world.spawn(1)
	sim.world.spawn(2)
	var inputs := {1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0}}
	sim.step(inputs)
	assert_eq(sim.tick, 1)
	assert_almost_eq(sim.world.get_pawn(1).pos.x, Stance.speed(Stance.STAND) * SimLoop.DT, 0.0001)
	assert_almost_eq(sim.world.get_pawn(2).pos.x, 0.0, 0.0001, "no input = no move")

func test_structures_block_movement() -> void:
	var cat = PieceCatalog.from_json_string('{"pieces":[{"id":"wall","height":"full","health":350,"blocks":"both"}]}')["catalog"]
	var store := StructureStore.new(cat)
	# Wall at ground cell (1,0,0): world x in [2,4), z in [0,2).
	store.place(1, 0, Vector3i(1, 0, 0), 0, 99)
	var sim := SimLoop.new()
	sim.structures = store
	var p := sim.world.spawn(1)
	p.pos = Vector3(1.0, 0.0, 1.0)
	# Drive straight toward +x into the wall for several ticks.
	for _i in 30:
		sim.step({1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.0, "buttons": 0}})
	# The pawn must NOT have entered the blocked cell.
	assert_eq(BuildGrid.cell_of(Vector3(p.pos.x, 0.0, p.pos.z)) == Vector3i(1, 0, 0), false)
	assert_true(p.pos.x < 2.0, "blocked before the wall cell, got x=%f" % p.pos.x)

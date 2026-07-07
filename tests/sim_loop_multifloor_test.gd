extends TestCase
## A pawn falls onto a structure floor and stands; walking a stair ramp raises it to the next floor.
const CAT := '{"pieces":[{"id":"bfloor","height":"full","health":350,"blocks":"both","surface":true},{"id":"bstair","height":"full","health":350,"blocks":"both","ramp":true}]}'

func _sim_with_floor(cell: Vector3i, type: int, yaw: int) -> SimLoop:
	var sim := SimLoop.new()
	sim.structures = StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])
	sim.structures.place(1, type, cell, yaw, 99)
	return sim

func test_pawn_settles_onto_structure_floor() -> void:
	var sim := _sim_with_floor(Vector3i(0, 1, 0), 0, 0)   # bfloor at cell y=1 -> surface 2.4
	var p := Pawn.new(1)
	p.pos = Vector3(1.0, 3.4, 1.0)   # dropped in above the floor
	p.grounded = false
	sim.world.pawns[1] = p
	for _i in 30:
		sim.step({1: {}})
	assert_almost_eq(p.pos.y, 2.4, 0.05, "pawn lands on the structure floor at y=2.4")
	assert_true(p.grounded, "grounded on the floor")

func test_walking_a_stair_ramp_raises_the_pawn() -> void:
	var sim := _sim_with_floor(Vector3i(0, 0, 0), 1, 0)   # bstair at cell y=0, yaw 0 (ascends +Z)
	# Landing floor at the top of the stair so the pawn stays elevated after climbing.
	sim.structures.place(2, 0, Vector3i(0, 1, 1), 0, 99)
	var p := Pawn.new(1)
	p.pos = Vector3(1.0, 0.0, 0.2)   # at the low edge of the stair
	sim.world.pawns[1] = p
	for _i in 15:
		sim.step({1: {"move_y": 1.0}})
	assert_true(p.pos.y > 1.5, "walking up the ramp raised the pawn toward the next floor (got y=%f)" % p.pos.y)

func test_landed_fall_records_drop_distance() -> void:
	var sim := SimLoop.new()   # no structures: pawn falls to the y=0 ground
	var p := Pawn.new(1)
	p.pos = Vector3(0.0, 10.0, 0.0)
	p.grounded = false
	p.fall_peak_y = 10.0
	sim.world.pawns[1] = p
	var seen_fall := 0.0
	for _i in 60:
		sim.step({1: {}})
		if p.landed_fall > 0.0:
			seen_fall = p.landed_fall
	assert_almost_eq(seen_fall, 10.0, 0.3, "landed_fall ~ the 10 m drop to ground")

func test_no_landed_fall_when_already_grounded() -> void:
	var sim := SimLoop.new()
	var p := Pawn.new(1)
	p.pos = Vector3(0.0, 0.0, 0.0)
	p.grounded = true
	sim.world.pawns[1] = p
	sim.step({1: {"move_x": 1.0}})
	assert_almost_eq(p.landed_fall, 0.0, 0.001, "walking on the ground records no fall")

func test_climb_test_twostory_reaches_upper_floor() -> void:
	# End-to-end: stamp the test_twostory prefab, walk a pawn in the door + up the interior stair,
	# and confirm it ends up standing on the upper floor (no climb glitch / fall-back).
	var cat := PieceCatalog.load_file("res://pieces/pieces.json")
	var store := StructureStore.new(cat)
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://buildings/test_twostory.json"))
	var id := 1
	for p in data["pieces"]:
		var off = p["offset"]
		store.place(id, cat.index_of(String(p["type"])), Vector3i(int(off[0]), int(off[1]), int(off[2])), int(p.get("yaw", 0)), -1, 1)
		id += 1
	var sim := SimLoop.new()
	sim.structures = store
	var pawn := Pawn.new(1)
	pawn.pos = Vector3(5.0, 0.0, -1.0)   # just south of the door (cell (2,0,0) = world x[4,6], z[0,2])
	sim.world.pawns[1] = pawn
	var max_y := 0.0
	for _i in 140:
		sim.step({1: {"move_y": 1.0}})   # walk north: door -> interior -> stair -> up
		max_y = maxf(max_y, pawn.pos.y)
	assert_true(max_y > 1.7, "reached the upper floor while climbing (max_y=%f)" % max_y)
	assert_true(pawn.pos.y > 1.5, "still on the upper floor at the end (y=%f, z=%f)" % [pawn.pos.y, pawn.pos.z])

func test_climb_twostory_house_reaches_top_floor() -> void:
	# Switchback stair rig: south door -> north flight -> mid landing -> south flight -> y=4 m deck.
	var cat := PieceCatalog.load_file("res://pieces/pieces.json")
	var store := StructureStore.new(cat)
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://buildings/twostory_house.json"))
	var id := 1
	for p in data["pieces"]:
		var off = p["offset"]
		store.place(id, cat.index_of(String(p["type"])), Vector3i(int(off[0]), int(off[1]), int(off[2])), int(p.get("yaw", 0)), -1, 1)
		id += 1
	var sim := SimLoop.new()
	sim.structures = store
	var pawn := Pawn.new(1)
	pawn.pos = Vector3(8.4, 0.0, -1.0)   # south of the door (cell (3,0,0) centre @ 2.4 m = x 8.4)
	sim.world.pawns[1] = pawn
	var max_y := 0.0
	for _i in 220:
		sim.step({1: {"move_y": 1.0}})   # walk north: door -> hall -> stair1 -> landing -> stair2
		max_y = maxf(max_y, pawn.pos.y)
	assert_true(max_y > 3.5, "reached the top living floor (max_y=%f)" % max_y)
	assert_true(pawn.pos.y > 3.5, "still on the top floor at the end (y=%f)" % pawn.pos.y)

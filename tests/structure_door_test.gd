extends TestCase
## A door piece has a walk-through aperture: resolve_movement lets a standing pawn pass a door cell,
## while a wall cell blocks. (The frame still blocks bullets/LOS via the whole-cell ray march.)

const CAT := '{"pieces":[{"id":"wall","height":"full","health":350,"blocks":"both"},{"id":"door","height":"full","health":350,"blocks":"both","passable":true}]}'

func test_passable_of_flag() -> void:
	var cat: PieceCatalog = PieceCatalog.from_json_string(CAT)["catalog"]
	assert_false(cat.passable_of(0), "wall is not passable")
	assert_true(cat.passable_of(1), "door is passable")

func test_wall_cell_blocks_movement() -> void:
	var store := StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])
	store.place(1, 0, Vector3i(1, 0, 0), 0, 99)   # wall (type 0) at cell (1,0,0): world x in [2,4]
	var to := Vector3(3.0, 0.0, 0.0)              # a point inside the wall cell
	var res := store.resolve_movement(Vector3(0, 0, 0), to)
	assert_true(res.distance_to(to) > 0.5, "wall blocks: pawn does not reach the wall cell")

func test_door_cell_is_passable() -> void:
	var store := StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])
	store.place(1, 1, Vector3i(1, 0, 0), 0, 99)   # door (type 1, passable) at cell (1,0,0)
	var to := Vector3(3.0, 0.0, 0.0)
	var res := store.resolve_movement(Vector3(0, 0, 0), to)
	assert_eq(res, to, "door aperture: pawn walks through")

func test_door_still_blocks_the_shot_ray() -> void:
	# Walk-through is movement-only; the door frame still blocks bullets until destroyed.
	var store := StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])
	store.place(1, 1, Vector3i(1, 0, 0), 0, 99)   # door at cell (1,0,0)
	var hit := store.march(Vector3(0.0, 1.0, 0.0), Vector3(1, 0, 0), 50.0)
	assert_eq(hit["hit"], true, "door frame still blocks the ray (whole-cell march)")

extends TestCase
## A wall blocks only at its own floor level; floors/stairs/doors are walk-through.
const CAT := '{"pieces":[{"id":"bwall","height":"full","health":350,"blocks":"both"},{"id":"bfloor","height":"full","health":350,"blocks":"both","surface":true},{"id":"bstair","height":"full","health":350,"blocks":"both","ramp":true},{"id":"bwall_door","height":"full","health":350,"blocks":"both","passable":true}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

func test_upper_wall_blocks_only_upstairs() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(1, 1, 0), 0, 99)   # wall at cell (1,1,0): blocks at y in [2.4,4.8]
	var up := s.resolve_movement(Vector3(1.0, 3.0, 1.0), Vector3(3.0, 3.0, 1.0))
	assert_true(up.distance_to(Vector3(3.0, 3.0, 1.0)) > 0.5, "upper-floor wall blocks at y=3 (upper cell)")
	var down := s.resolve_movement(Vector3(1.0, 0.0, 1.0), Vector3(3.0, 0.0, 1.0))
	assert_eq(down, Vector3(3.0, 0.0, 1.0), "ground floor under an upper wall is clear")

func test_ground_wall_still_blocks() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(1, 0, 0), 0, 99)
	var r := s.resolve_movement(Vector3(1.0, 0.0, 1.0), Vector3(3.0, 0.0, 1.0))
	assert_true(r.distance_to(Vector3(3.0, 0.0, 1.0)) > 0.5, "ground wall blocks")

func test_floor_and_stair_and_door_do_not_block_walking() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(1, 0, 0), 0, 99)   # bfloor at ground
	s.place(2, 2, Vector3i(3, 0, 0), 0, 99)   # bstair at ground (x cell 3 -> world [6,8])
	s.place(3, 3, Vector3i(5, 0, 0), 0, 99)   # bwall_door at ground (x cell 5 -> world [10,12])
	assert_eq(s.resolve_movement(Vector3(1,0,1), Vector3(3,0,1)), Vector3(3,0,1), "floor cell walkable")
	assert_eq(s.resolve_movement(Vector3(5,0,1), Vector3(7,0,1)), Vector3(7,0,1), "stair cell walkable")
	assert_eq(s.resolve_movement(Vector3(9,0,1), Vector3(11,0,1)), Vector3(11,0,1), "door cell walkable")

const HALF_CAT := '{"pieces":[{"id":"sandbag","height":"half","health":100,"blocks":"both"}]}'

func test_ground_blocker_top_is_height_relative() -> void:
	# A half-piece on the GROUND below an upper floor must NOT register as a vaultable blocker for a
	# pawn on the upper floor (else they'd vault-teleport down — M14 final-review fix).
	var s := StructureStore.new(PieceCatalog.from_json_string(HALF_CAT)["catalog"])
	s.place(1, 0, Vector3i(0, 0, 0), 0, 99)   # half sandbag at the GROUND cell (0,0,0)
	assert_almost_eq(s.ground_blocker_top(Vector3(1.0, 2.5, 1.0)), 0.0, 0.01, "ground half-piece is not a blocker from the upper floor")
	assert_almost_eq(s.ground_blocker_top(Vector3(1.0, 0.0, 1.0)), 1.2, 0.01, "same half-piece is a 1.2m vaultable blocker at ground level (unchanged)")

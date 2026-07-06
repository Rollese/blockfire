extends TestCase
## M11 Gate-B — WALK-THROUGH. A carved chunked wall stops blocking pawn movement once a floor-level
## breach wide + tall enough opens in the pawn's column; an intact wall (or a small/high shot-through
## hole) still blocks. Geometry: a grid-8 wall in cell (1,0,0) spans x:[2,4] z:[0,2]; yaw 0 -> U = X
## width. A pawn crosses in +Z at x=3 (face centre).

const CAT := '{"pieces":[{"id":"cwall","height":"full","health":350,"chunk_grid":8}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

# --- pure ChunkMask.region_clear ---

func test_region_clear_false_on_full_mask() -> void:
	var full := ChunkMask.full_mask(8)
	assert_false(ChunkMask.region_clear(full, Vector3i(1, 0, 0), 0, 8, 2.0, Vector3(3, 0.1, 1), 0.35, 1.5),
		"a pristine wall is not walk-through")

func test_region_clear_true_when_column_carved() -> void:
	# Clear a wide low breach at the face centre, then the pawn column reads clear.
	var breached := ChunkMask.clear_in_radius(ChunkMask.full_mask(8), Vector3i(1, 0, 0), 0, 8, 2.0, Vector3(3, 0.6, 0), 1.2)
	assert_true(ChunkMask.region_clear(breached, Vector3i(1, 0, 0), 0, 8, 2.0, Vector3(3, 0.1, 1), 0.35, 1.5),
		"a wide floor-level breach is walk-through at the pawn column")

# --- resolve_movement behaviour ---

func test_intact_wall_blocks_crossing() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(1, 0, 0), 0, 7)   # wall z:[0,2]
	var out := s.resolve_movement(Vector3(3, 0, -1), Vector3(3, 0, 1))
	assert_true(out.z < 0.0, "an intact wall keeps the pawn on the near side (no crossing)")

func test_floor_breach_lets_the_pawn_walk_through() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(1, 0, 0), 0, 7)
	# Blow a wide, floor-level breach at the crossing column (x=3), like a rocket/repeated fire.
	s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, Vector3(3, 0.6, 0), 1.2)
	var out := s.resolve_movement(Vector3(3, 0, -1), Vector3(3, 0, 1))
	assert_true(out.z > 0.0, "a floor-level breach lets the pawn step through to the far side")

func test_high_hole_still_blocks_the_feet() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(1, 0, 0), 0, 7)
	# A small hole high on the wall (chest height) — shoot-through, but the feet still hit solid chunks.
	s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, Vector3(3, 1.6, 0), 0.4)
	var out := s.resolve_movement(Vector3(3, 0, -1), Vector3(3, 0, 1))
	assert_true(out.z < 0.0, "a high shot-through hole does not let the pawn walk through")

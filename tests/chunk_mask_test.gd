extends TestCase

func test_full_mask_and_count() -> void:
	assert_eq(ChunkMask.count(1), 1)
	assert_eq(ChunkMask.count(8), 64)
	assert_eq(ChunkMask.full_mask(1), 1)
	assert_eq(ChunkMask.popcount(ChunkMask.full_mask(8)), 64)   # all 64 bits set
	assert_eq(ChunkMask.popcount(ChunkMask.full_mask(4)), 16)

func test_clear_in_radius_clears_only_near_chunks() -> void:
	var cell := Vector3i(0, 0, 0)
	var grid := 8
	var full := ChunkMask.full_mask(grid)
	var height := 2.0
	var impact := ChunkMask.chunk_center(cell, 0, 0, 0, grid, height)
	var after := ChunkMask.clear_in_radius(full, cell, 0, grid, height, impact, 0.3)
	assert_true(ChunkMask.popcount(after) < 64, "some chunks cleared")
	assert_true(ChunkMask.popcount(after) > 0, "not all chunks cleared")
	assert_false(ChunkMask.is_alive_at(after, cell, 0, grid, height, impact), "hit chunk is dead")
	# A1: the carve edge is deterministically jittered (ragged, not a clean circle), so the exact count
	# varies at the rim — a small radius still clears just a local nick (core: hit + orthogonal neighbours).
	var cleared := 64 - ChunkMask.popcount(after)
	assert_true(cleared >= 3 and cleared <= 6, "a small local nick with a ragged edge (cleared %d)" % cleared)
	assert_false(ChunkMask.is_alive_at(after, cell, 0, grid, height, ChunkMask.chunk_center(cell, 0, 0, 1, grid, height)), "orthogonal neighbour cleared")

func test_clear_whole_face_destroys() -> void:
	var cell := Vector3i(0, 0, 0)
	var grid := 8
	var full := ChunkMask.full_mask(grid)
	var center := ChunkMask.chunk_center(cell, 0, 3, 3, grid, 2.0)
	var after := ChunkMask.clear_in_radius(full, cell, 0, grid, 2.0, center, 100.0)
	assert_eq(after, 0)

func test_clear_is_monotonic_and_idempotent() -> void:
	var cell := Vector3i(2, 1, -3)
	var grid := 8
	var m := ChunkMask.full_mask(grid)
	var impact := ChunkMask.chunk_center(cell, 2, 4, 4, grid, 2.0)
	var once := ChunkMask.clear_in_radius(m, cell, 2, grid, 2.0, impact, 0.5)
	var twice := ChunkMask.clear_in_radius(once, cell, 2, grid, 2.0, impact, 0.5)
	assert_eq(once, twice, "re-clearing same impact is a no-op")
	assert_true(ChunkMask.popcount(once) <= ChunkMask.popcount(m), "bits only clear")

func test_isolated_chunk_is_dropped() -> void:
	# A single chunk with all four face-neighbours cleared can't hang alone in a hole (playtest artifact).
	var lone := 1 << (4 * 8 + 4)
	assert_eq(ChunkMask._drop_isolated(lone, 8), 0, "a lone floating chunk falls")

func test_connected_chunks_survive_the_isolated_drop() -> void:
	var pair := (1 << (4 * 8 + 4)) | (1 << (4 * 8 + 5))   # two horizontally adjacent chunks
	assert_eq(ChunkMask.popcount(ChunkMask._drop_isolated(pair, 8)), 2, "a connected pair stays put")

func test_carve_is_direction_independent() -> void:
	# Wall at cell(0,0,0) yaw 0: face is X-Y, thin in Z. A hit from the -Z (south) side and the +Z
	# (north) side at the same face point must carve the SAME chunks (playtest: N/E walls barely carved).
	var full := ChunkMask.full_mask(8)
	var from_south := ChunkMask.clear_in_radius(full, Vector3i(0, 0, 0), 0, 8, 2.0, Vector3(1.0, 1.0, 0.0), 0.6)
	var from_north := ChunkMask.clear_in_radius(full, Vector3i(0, 0, 0), 0, 8, 2.0, Vector3(1.0, 1.0, 2.0), 0.6)
	assert_true(ChunkMask.popcount(from_south) < 64, "the hit carves chunks")
	assert_eq(from_south, from_north, "a north-side and a south-side hit carve identically")

func test_depth_gate_rejects_a_blast_off_the_wall_plane() -> void:
	var full := ChunkMask.full_mask(8)
	# 4 m off the wall's plane (a parallel wall behind the one that was hit) — must not be carved.
	var far := ChunkMask.clear_in_radius(full, Vector3i(0, 0, 0), 0, 8, 2.0, Vector3(1.0, 1.0, 5.0), 1.3)
	assert_eq(far, full, "a blast well off a wall's plane doesn't punch through it")

func test_is_empty() -> void:
	assert_true(ChunkMask.is_empty(0))
	assert_false(ChunkMask.is_empty(1))
	assert_false(ChunkMask.is_empty(ChunkMask.full_mask(8)))

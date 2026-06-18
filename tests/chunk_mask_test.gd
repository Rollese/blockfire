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

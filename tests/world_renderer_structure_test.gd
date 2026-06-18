extends TestCase
## WorldRenderer structure damage mapping: M11 replaced the M4 `bucket` field with a per-face chunk
## alive-mask, so the renderer must derive the StructureKit damage tier (3 pristine .. 0 heavy) from
## the live `chunks` mask. Regression guard: the renderer used to read a now-absent `bucket` field and
## froze every piece at pristine, never reacting to RPG/explosive damage.

const GRID := 8   # fortifications.json chunk_grid for sandbag + wall

func test_full_mask_is_pristine_bucket() -> void:
	var full := ChunkMask.full_mask(GRID)
	assert_eq(WorldRenderer.damage_bucket(full, GRID), 3, "intact piece reads pristine (bucket 3)")

func test_single_chunk_left_is_heavy_bucket() -> void:
	# One chunk intact out of 64 -> heaviest damage tier (chipped silhouette).
	assert_eq(WorldRenderer.damage_bucket(1, GRID), 0, "almost-destroyed piece reads heavy (bucket 0)")

func test_bucket_decreases_monotonically_as_chunks_are_destroyed() -> void:
	var full := ChunkMask.full_mask(GRID)
	var prev := WorldRenderer.damage_bucket(full, GRID)
	var m := full
	# Clear chunks one bit at a time; the bucket must never increase as damage accumulates.
	for i in 64:
		m &= ~(1 << i)
		var b := WorldRenderer.damage_bucket(m, GRID)
		assert_true(b <= prev, "bucket never rises while chunks are destroyed")
		prev = b
	assert_eq(prev, 0, "fully cleared mask bottoms out at heavy (bucket 0)")

func test_struct_key_reflects_chunk_damage() -> void:
	# The cache key drives rebuilds; it must change when the chunk mask changes so a damaged piece
	# gets re-skinned instead of staying frozen at its pristine geometry.
	var r := WorldRenderer.new()
	var full := ChunkMask.full_mask(GRID)
	var pristine_key := r._struct_key({"type": 1, "chunks": full})
	var damaged_key := r._struct_key({"type": 1, "chunks": 1})
	assert_true(pristine_key != damaged_key, "key changes between pristine and damaged chunk masks")
	r.free()

func test_missing_chunks_defaults_to_pristine() -> void:
	# A record without a chunks field (defensive) must read pristine, not destroyed.
	assert_eq(WorldRenderer.damage_bucket(ChunkMask.full_mask(GRID), GRID),
		WorldRenderer.damage_bucket(-1, GRID), "all-bits-set default equals full-mask pristine")

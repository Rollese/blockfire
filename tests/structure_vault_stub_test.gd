extends TestCase
## M11 Gate-B R4: a wall shot down from the TOP to a low stub reads as a low, vaultable blocker (its
## effective top = the top surviving chunk row), so you can climb over the breach you made. A pristine
## wall — or one with only a MIDDLE hole (top intact) — is still a tall, non-vaultable blocker.

const CAT := '{"pieces":[{"id":"cwall","height":"full","health":350,"chunk_grid":8}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

# --- pure ChunkMask.top_alive_height ---

func test_full_mask_is_full_height() -> void:
	assert_almost_eq(ChunkMask.top_alive_height(ChunkMask.full_mask(8), 8, 2.0), 2.0, 0.001, "pristine wall = full height")

func test_top_rows_cleared_lowers_the_top() -> void:
	var stub := ChunkMask.full_mask(8) & 0x00000000FFFFFFFF   # keep rows 0-3 (bits 0-31), clear rows 4-7
	assert_almost_eq(ChunkMask.top_alive_height(stub, 8, 2.0), 1.0, 0.001, "top half gone -> 1.0 m top")

func test_empty_is_zero() -> void:
	assert_almost_eq(ChunkMask.top_alive_height(0, 8, 2.0), 0.0, 0.001, "no chunks -> no height")

# --- vault behaviour via the store ---

func test_pristine_wall_is_a_tall_blocker() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 0, 0)
	assert_true(s.is_tall_blocker(Vector3(1, 0, 1)), "a pristine full wall cannot be vaulted")

func test_top_carved_stub_is_vaultable() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 0, 0)
	# Blow the TOP off the wall (impact high on the face) — leaves a low stub.
	var top := ChunkMask.chunk_center(Vector3i(0, 0, 0), 0, 7, 4, 8, 2.0)
	s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, top, 1.4)
	assert_false(s.get_record(1).is_empty(), "the stub is still there (not fully removed)")
	assert_false(s.is_tall_blocker(Vector3(1, 0, 1)), "a wall shot down to a stub is now low")
	var blocker_top := s.ground_blocker_top(Vector3(1, 0, 1))
	assert_true(blocker_top > 0.0 and blocker_top <= Vault.VAULT_MAX_HEIGHT, "the stub top is within vault reach (%.2f m)" % blocker_top)

func test_middle_hole_wall_is_still_tall() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 0, 0)
	# A hole through the MIDDLE (top rows intact) — you shoot/walk through it, but can't vault it.
	var mid := ChunkMask.chunk_center(Vector3i(0, 0, 0), 0, 4, 4, 8, 2.0)
	s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, mid, 0.5)
	assert_true(s.is_tall_blocker(Vector3(1, 0, 1)), "a middle-hole wall with an intact top is still tall")

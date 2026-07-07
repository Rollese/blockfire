extends TestCase
## M11 Gate-B R3: a heavily-carved (below SUPPORT_MIN_FRACTION) structural wall stops bearing load, so
## the floor/wall above it orphans and collapses instead of floating on a holey wall. A single breach
## (one hole) leaves enough of the wall that it still supports — it takes sustained damage to drop it.

func _wall_type(cat: PieceCatalog) -> int:
	for i in cat.size():
		if cat.name_of(i) == "bwall":
			return i
	return -1

func _stack() -> Dictionary:
	# Two full walls stacked at y=0 (base) and y=1 (upper), same building_id.
	var cat := PieceCatalog.load_file("res://pieces/pieces.json")
	var store := StructureStore.new(cat)
	var t := _wall_type(cat)
	store.place(30, t, Vector3i(0, 0, 0), 0, -1, 3)
	store.place(31, t, Vector3i(0, 1, 0), 0, -1, 3)
	return {"store": store, "type": t}

func test_intact_base_wall_supports_the_wall_above() -> void:
	var s: StructureStore = _stack()["store"]
	assert_true(s.support_intact(30), "a pristine wall bears load")
	assert_eq(Support.orphaned_after(s, 3, []).size(), 0, "nothing orphaned while the base is intact")

func test_single_breach_still_supports() -> void:
	var d := _stack()
	var s: StructureStore = d["store"]
	# One RPG-sized hole in the base wall — most of the wall remains, so it still holds up the floor.
	var impact := ChunkMask.chunk_center(Vector3i(0, 0, 0), 0, 4, 4, 8, 2.0)
	s.damage_chunks(30, PieceCatalog.SRC_EXPLOSIVE, impact, 0.6)
	assert_true(s.support_intact(30), "one breach doesn't drop the wall below the load fraction")
	assert_false(Support.orphaned_after(s, 3, []).has(31), "the upper wall does not collapse from a single hole")

func test_carved_out_base_wall_drops_the_wall_above() -> void:
	var d := _stack()
	var s: StructureStore = d["store"]
	# Blow most of the base wall away (still present, but well below the support fraction).
	var impact := ChunkMask.chunk_center(Vector3i(0, 0, 0), 0, 4, 4, 8, 2.0)
	s.damage_chunks(30, PieceCatalog.SRC_EXPLOSIVE, impact, 1.5)
	assert_true(s.get_record(30).size() > 0, "the base wall is carved, not fully removed")
	assert_false(s.support_intact(30), "a mostly-destroyed base wall no longer bears load")
	assert_true(Support.orphaned_after(s, 3, []).has(31), "the wall above orphans (collapses) — no floating")

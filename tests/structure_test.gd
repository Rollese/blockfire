extends TestCase

const CAT := '{"pieces":[{"id":"sandbag","height":"half","health":150,"blocks":"both","chunk_grid":8},{"id":"wall","height":"full","health":350,"blocks":"both","chunk_grid":8}]}'
const CAT_IMMUNE := '{"pieces":[{"id":"bwall","height":"full","health":800,"chunk_grid":8,"damage":["explosive","melee"]}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

func test_place_indexes_record() -> void:
	var s := _store()
	var rec := s.place(1, 1, Vector3i(2, 0, 3), 0, 7)
	assert_eq(rec["id"], 1)
	assert_eq(rec["chunks"], ChunkMask.full_mask(8))
	assert_eq(rec["building_id"], 0)
	assert_eq(s.count(), 1)
	assert_eq(s.occupied(Vector3i(2, 0, 3)), true)
	assert_eq(s.owner_count(7), 1)

func test_place_with_building_id() -> void:
	var s := _store()
	var rec := s.place(5, 1, Vector3i(4, 0, 4), 0, 0, 42)
	assert_eq(rec["building_id"], 42)

func test_place_on_occupied_cell_fails() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	var rec := s.place(2, 0, Vector3i(0, 0, 0), 0, 7)
	assert_eq(rec.is_empty(), true)
	assert_eq(s.count(), 1)

func test_remove_frees_cell() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	s.remove(1)
	assert_eq(s.count(), 0)
	assert_eq(s.occupied(Vector3i(0, 0, 0)), false)
	assert_eq(s.owner_count(7), 0)

func test_recycle_oldest_is_fifo() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	s.place(2, 0, Vector3i(1, 0, 0), 0, 7)
	var removed := s.recycle_oldest(7)
	assert_eq(removed, 1)
	assert_eq(s.occupied(Vector3i(0, 0, 0)), false)
	assert_eq(s.occupied(Vector3i(1, 0, 0)), true)

func test_region_index_groups_by_interest_cell() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	s.place(2, 0, Vector3i(1, 0, 0), 0, 7)
	var region := s.region_of(Vector3i(0, 0, 0))
	assert_eq(s.region_of(Vector3i(1, 0, 0)), region)
	assert_eq(s.records_in_region(region).size(), 2)

func test_validate_rejects_occupied_and_oob_and_cooldown() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	var ppos := Vector3(0.0, 0.0, 3.0)
	assert_eq(s.validate_place(Vector3i(0, 0, 0), ppos, 1000, 0, 1000.0)["ok"], false)
	assert_eq(s.validate_place(Vector3i(9999, 0, 0), ppos, 1000, 0, 1000.0)["ok"], false)
	assert_eq(s.validate_place(Vector3i(0, 0, 1), ppos, 10, 0, 1000.0)["ok"], false)

func test_validate_rejects_out_of_range_and_self_cell() -> void:
	var s := _store()
	var ppos := Vector3(0.0, 0.0, 0.0)
	assert_eq(s.validate_place(Vector3i(0, 0, 0), ppos, 1000, 0, 1000.0)["ok"], false)
	assert_eq(s.validate_place(Vector3i(10, 0, 0), ppos, 1000, 0, 1000.0)["ok"], false)

func test_validate_requires_support_when_stacked() -> void:
	var s := _store()
	var ppos := Vector3(1.0, 0.0, 1.0)
	assert_eq(s.validate_place(Vector3i(0, 1, 0), ppos, 1000, 0, 1000.0)["ok"], false)
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	assert_eq(s.validate_place(Vector3i(0, 1, 0), ppos, 1000, 0, 1000.0)["ok"], true)

func test_validate_accepts_valid() -> void:
	var s := _store()
	var ppos := Vector3(0.0, 0.0, 1.0)
	assert_eq(s.validate_place(Vector3i(0, 0, 1), ppos, 1000, 0, 1000.0)["ok"], true)

func test_oldest_id_peeks_without_removing() -> void:
	var s := _store()
	assert_eq(s.oldest_id(7), 0)
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	s.place(2, 0, Vector3i(1, 0, 0), 0, 7)
	assert_eq(s.oldest_id(7), 1)
	assert_eq(s.count(), 2)
	assert_eq(s.oldest_id(7), 1)

func test_damage_chunks_clears_and_destroys() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 0, 0), 0, 0)
	var center := BuildGrid.cell_min(Vector3i(0, 0, 0)) + Vector3(1, 1, 0)
	var r1 := s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, center, 0.4)
	assert_eq(r1["hit"], true)
	assert_eq(r1["destroyed"], false)
	assert_true(ChunkMask.popcount(r1["mask"]) < 64, "some chunks gone")
	assert_eq(s.count(), 1)
	var r2 := s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, center, 100.0)
	assert_eq(r2["destroyed"], true)
	assert_eq(r2["mask"], 0)
	assert_eq(s.count(), 0)
	assert_eq(s.occupied(Vector3i(0, 0, 0)), false)

func test_damage_chunks_respects_immunity() -> void:
	var s := StructureStore.new(PieceCatalog.from_json_string(CAT_IMMUNE)["catalog"])
	s.place(1, 0, Vector3i(0, 0, 0), 0, 0)
	var center := BuildGrid.cell_min(Vector3i(0, 0, 0)) + Vector3(1, 1, 0)
	assert_eq(s.damage_chunks(1, PieceCatalog.SRC_BULLET, center, 100.0)["hit"], false)
	assert_eq(s.count(), 1)
	assert_eq(s.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, center, 100.0)["destroyed"], true)

func test_damage_chunks_unknown_id() -> void:
	var s := _store()
	assert_eq(s.damage_chunks(99, PieceCatalog.SRC_EXPLOSIVE, Vector3.ZERO, 1.0)["hit"], false)

func test_ids_in_radius_returns_occupied_within_range() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 0, 0), 0, 7)
	s.place(2, 1, Vector3i(2, 0, 0), 0, 7)
	s.place(3, 1, Vector3i(3, 0, 0), 0, 7)
	var near := s.ids_in_radius(Vector3(1, 1, 1), 3.0)
	assert_eq(near.size(), 1)
	assert_eq(near[0], 1)
	var wider := s.ids_in_radius(Vector3(1, 1, 1), 4.5)
	assert_eq(wider.size(), 2)
	assert_eq(wider.has(1) and wider.has(2), true)

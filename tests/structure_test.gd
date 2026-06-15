extends TestCase

const CAT := '{"pieces":[{"id":"sandbag","height":"half","health":150,"blocks":"both"},{"id":"wall","height":"full","health":350,"blocks":"both"}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

func test_place_indexes_record() -> void:
	var s := _store()
	var rec := s.place(1, 1, Vector3i(2, 0, 3), 0, 7)   # type=wall, owner=7
	assert_eq(rec["id"], 1)
	assert_eq(rec["health"], 350)
	assert_eq(s.count(), 1)
	assert_eq(s.occupied(Vector3i(2, 0, 3)), true)
	assert_eq(s.owner_count(7), 1)

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
	assert_eq(removed, 1)               # the first placed
	assert_eq(s.occupied(Vector3i(0, 0, 0)), false)
	assert_eq(s.occupied(Vector3i(1, 0, 0)), true)

func test_region_index_groups_by_interest_cell() -> void:
	var s := _store()
	# Cells (0,0,0) and (1,0,0) are 2m apart -> same 64m interest region.
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	s.place(2, 0, Vector3i(1, 0, 0), 0, 7)
	var region := s.region_of(Vector3i(0, 0, 0))
	assert_eq(s.region_of(Vector3i(1, 0, 0)), region)
	assert_eq(s.records_in_region(region).size(), 2)

func test_validate_rejects_occupied_and_oob_and_cooldown() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	var ppos := Vector3(0.0, 0.0, 3.0)   # ~near cell (0,0,1)
	# occupied
	assert_eq(s.validate_place(Vector3i(0, 0, 0), ppos, 1000, 0, 1000.0)["ok"], false)
	# out of bounds
	assert_eq(s.validate_place(Vector3i(9999, 0, 0), ppos, 1000, 0, 1000.0)["ok"], false)
	# cooldown (now=10, last=0, cooldown 150)
	assert_eq(s.validate_place(Vector3i(0, 0, 1), ppos, 10, 0, 1000.0)["ok"], false)

func test_validate_rejects_out_of_range_and_self_cell() -> void:
	var s := _store()
	var ppos := Vector3(0.0, 0.0, 0.0)            # ground cell (0,0,0)
	# self cell
	assert_eq(s.validate_place(Vector3i(0, 0, 0), ppos, 1000, 0, 1000.0)["ok"], false)
	# far away (> BUILD_RANGE 5m): cell (10,0,0) centre is 21m away
	assert_eq(s.validate_place(Vector3i(10, 0, 0), ppos, 1000, 0, 1000.0)["ok"], false)

func test_validate_requires_support_when_stacked() -> void:
	var s := _store()
	var ppos := Vector3(1.0, 0.0, 1.0)
	# cy=1 with nothing below -> reject
	assert_eq(s.validate_place(Vector3i(0, 1, 0), ppos, 1000, 0, 1000.0)["ok"], false)
	# place a ground piece, then cy=1 above it is supported
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	assert_eq(s.validate_place(Vector3i(0, 1, 0), ppos, 1000, 0, 1000.0)["ok"], true)

func test_validate_accepts_valid() -> void:
	var s := _store()
	var ppos := Vector3(0.0, 0.0, 1.0)   # player in cell (0,0,0); place into adjacent (0,0,1)
	assert_eq(s.validate_place(Vector3i(0, 0, 1), ppos, 1000, 0, 1000.0)["ok"], true)

func test_oldest_id_peeks_without_removing() -> void:
	var s := _store()
	assert_eq(s.oldest_id(7), 0)                  # none yet
	s.place(1, 0, Vector3i(0, 0, 0), 0, 7)
	s.place(2, 0, Vector3i(1, 0, 0), 0, 7)
	assert_eq(s.oldest_id(7), 1)                  # FIFO front
	assert_eq(s.count(), 2)                       # peek did NOT remove
	assert_eq(s.oldest_id(7), 1)                  # still there

func test_bucket_of_thresholds() -> void:
	assert_eq(StructureStore.bucket_of(100, 100), 3)   # pristine
	assert_eq(StructureStore.bucket_of(80, 100), 3)    # >0.75
	assert_eq(StructureStore.bucket_of(75, 100), 2)    # ==0.75 -> not >0.75
	assert_eq(StructureStore.bucket_of(60, 100), 2)
	assert_eq(StructureStore.bucket_of(50, 100), 1)
	assert_eq(StructureStore.bucket_of(40, 100), 1)
	assert_eq(StructureStore.bucket_of(25, 100), 0)
	assert_eq(StructureStore.bucket_of(10, 100), 0)
	assert_eq(StructureStore.bucket_of(5, 0), 0)       # guard: max 0

func test_apply_damage_reduces_health_and_buckets() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 0, 0), 0, 7)             # wall, health 350
	var r := s.apply_damage(1, 100)                    # 250/350 = 0.714 -> bucket 2
	assert_eq(r["hit"], true)
	assert_eq(r["destroyed"], false)
	assert_eq(r["health"], 250)
	assert_eq(r["bucket"], 2)
	assert_eq(s.get_record(1)["health"], 250)

func test_apply_damage_destroys_and_frees_cell() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 0, 0), 0, 7)
	var r := s.apply_damage(1, 400)                    # lethal
	assert_eq(r["destroyed"], true)
	assert_eq(r["health"], 0)
	assert_eq(s.count(), 0)
	assert_eq(s.occupied(Vector3i(0, 0, 0)), false)
	assert_eq(s.owner_count(7), 0)

func test_apply_damage_unknown_id_is_noop() -> void:
	var s := _store()
	assert_eq(s.apply_damage(999, 50)["hit"], false)

func test_ids_in_radius_returns_occupied_within_range() -> void:
	var s := _store()
	# cell centres: (0,0,0)->(1,1,1), (2,0,0)->(5,1,1), (3,0,0)->(7,1,1)
	s.place(1, 1, Vector3i(0, 0, 0), 0, 7)
	s.place(2, 1, Vector3i(2, 0, 0), 0, 7)
	s.place(3, 1, Vector3i(3, 0, 0), 0, 7)
	var near := s.ids_in_radius(Vector3(1, 1, 1), 3.0)   # only id1 (id2 is 4m away)
	assert_eq(near.size(), 1)
	assert_eq(near[0], 1)
	var wider := s.ids_in_radius(Vector3(1, 1, 1), 4.5)  # id1 (0m) + id2 (4m)
	assert_eq(wider.size(), 2)
	assert_eq(wider.has(1) and wider.has(2), true)

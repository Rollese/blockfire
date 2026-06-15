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

extends TestCase
## BuildSiteStore (M12-P2): holds active build sites (no collision until complete). Mirrors the
## StructureStore region/occupancy indexing so the server can validate placement against both stores
## and stream sites by interest region.

func _site(id: int, cell: Vector3i, owner: int = 1) -> Dictionary:
	return {"id": id, "owner": owner, "team": 0, "type": 0, "cell": cell, "yaw": 0,
		"build_progress": 0.0, "build_cost": 90, "min_builders": 1, "last_work_tick": 0}

func test_add_get_remove() -> void:
	var s := BuildSiteStore.new()
	s.add(_site(5, Vector3i(1, 0, 1)))
	assert_eq(s.count(), 1)
	assert_eq(int(s.get_site(5)["id"]), 5, "get_site returns the record")
	assert_true(s.occupied(Vector3i(1, 0, 1)), "site occupies its cell")
	s.remove(5)
	assert_eq(s.count(), 0)
	assert_false(s.occupied(Vector3i(1, 0, 1)), "cell freed on remove")

func test_owner_count_and_oldest() -> void:
	var s := BuildSiteStore.new()
	s.add(_site(1, Vector3i(0, 0, 0)))
	s.add(_site(2, Vector3i(2, 0, 0)))
	assert_eq(s.owner_count(1), 2)
	assert_eq(s.oldest_id(1), 1, "FIFO: oldest is the first placed")
	s.remove(1)
	assert_eq(s.oldest_id(1), 2, "after removing the oldest, next becomes oldest")

func test_records_in_region() -> void:
	var s := BuildSiteStore.new()
	s.add(_site(7, Vector3i(0, 0, 0)))
	var region := s.region_of(Vector3i(0, 0, 0))
	var recs := s.records_in_region(region)
	assert_eq(recs.size(), 1, "site streamed in its region")
	assert_eq(int(recs[0]["id"]), 7)

func test_get_missing_returns_empty() -> void:
	assert_eq(BuildSiteStore.new().get_site(999).size(), 0, "missing id -> empty dict")

func test_ids_lists_all() -> void:
	var s := BuildSiteStore.new()
	s.add(_site(3, Vector3i(0, 0, 0)))
	s.add(_site(4, Vector3i(5, 0, 5)))
	assert_eq(s.ids().size(), 2, "ids() lists every active site")

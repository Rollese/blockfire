extends TestCase

func test_ground_blocker_top_half_and_full_and_empty() -> void:
	var cat_res := PieceCatalog.from_json_string('{"pieces":[{"id":"sb","height":"half","health":100,"material":"METAL_THIN"},{"id":"wl","height":"full","health":100,"material":"CONCRETE"}]}')
	var store := StructureStore.new(cat_res["catalog"])
	# Place a half piece (type 0) and a full piece (type 1) at known ground cells.
	store.place(1, 0, BuildGrid.cell_of(Vector3(10, 0, 10)), 0, 0)
	store.place(2, 1, BuildGrid.cell_of(Vector3(20, 0, 20)), 0, 0)
	assert_almost_eq(store.ground_blocker_top(Vector3(10, 0, 10)), 1.2)   # half -> 0.5 * CELL_SIZE(2.4)
	assert_almost_eq(store.ground_blocker_top(Vector3(20, 0, 20)), 2.4)   # full -> CELL_SIZE
	assert_almost_eq(store.ground_blocker_top(Vector3(0, 0, 0)), 0.0)     # empty cell

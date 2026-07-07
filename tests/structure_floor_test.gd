extends TestCase
## floor_height_at returns the highest walkable structure surface at/below a query height.
const CAT := '{"pieces":[{"id":"bfloor","height":"full","health":350,"blocks":"both","surface":true},{"id":"bstair","height":"full","health":350,"blocks":"both","ramp":true},{"id":"bwall","height":"full","health":350,"blocks":"both"}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

func test_no_structure_returns_neg_inf() -> void:
	assert_true(_store().floor_height_at(1.0, 1.0, 5.0) == -INF, "empty column -> -INF")

func test_floor_surface_is_cell_base() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 1, 0), 0, 99)   # bfloor (type 0) at cell y=1 -> surface 2.4
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 3.0), 2.4, 0.01, "floor at cell 1 -> surface 2.4")

func test_returns_highest_at_or_below_query() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 99)   # floor at y=0 -> surface 0.0
	s.place(2, 0, Vector3i(0, 1, 0), 0, 99)   # floor at y=1 -> surface 2.4
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 2.8), 2.4, 0.01, "standing high -> upper floor")
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 1.0), 0.0, 0.01, "below upper floor -> lower floor")

func test_stair_cell_returns_ramped_height() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(0, 1, 0), 0, 99)   # bstair (type 1) at cell y=1, yaw 0 (ascends +Z)
	assert_almost_eq(s.floor_height_at(1.0, 0.0, 4.0), 2.4, 0.05, "stair low edge ~ base")
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 4.0), 3.4, 0.05, "stair mid ~ partway up")

func test_wall_provides_base_surface() -> void:
	# A wall provides a standable surface at its cell base (so a building level is a continuous floor).
	var s := _store()
	s.place(1, 2, Vector3i(0, 1, 0), 0, 99)   # bwall (type 2) at cell y=1 -> base surface 2.4
	assert_almost_eq(s.floor_height_at(1.0, 1.0, 3.0), 2.4, 0.01, "wall base is standable at the cell-base plane")

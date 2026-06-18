extends TestCase
## Support: foundation + orphan flood-fill over a StructureStore building.

func _store_with_column() -> StructureStore:
	# A vertical stack of 3 bcolumn pieces (building_id 1) at x=0,z=0, y=0,1,2.
	var cat := PieceCatalog.load_file("res://pieces/pieces.json")
	var store := StructureStore.new(cat)
	var bcol := -1
	for i in cat.size():
		if cat.name_of(i) == "bcolumn": bcol = i
	store.place(10, bcol, Vector3i(0, 0, 0), 0, -1, 1)
	store.place(11, bcol, Vector3i(0, 1, 0), 0, -1, 1)
	store.place(12, bcol, Vector3i(0, 2, 0), 0, -1, 1)
	return store

func test_nothing_orphaned_when_foundation_intact() -> void:
	var store := _store_with_column()
	var orphans := Support.orphaned_after(store, 1, [])
	assert_eq(orphans.size(), 0, "intact stack has no orphans")

func test_removing_foundation_orphans_everything_above() -> void:
	var store := _store_with_column()
	store.remove(10)  # knock out the y=0 foundation piece
	var orphans := Support.orphaned_after(store, 1, [10])
	# y=1 and y=2 are now disconnected from any y==0 foundation -> both orphaned.
	assert_eq(orphans.size(), 2, "two pieces orphaned")
	assert_true(orphans.has(11) and orphans.has(12), "the upper pieces are the orphans")

func test_other_building_unaffected() -> void:
	var store := _store_with_column()
	var cat := PieceCatalog.load_file("res://pieces/pieces.json")
	var bcol := -1
	for i in cat.size():
		if cat.name_of(i) == "bcolumn": bcol = i
	store.place(20, bcol, Vector3i(5, 0, 0), 0, -1, 2)  # different building_id
	store.remove(10)
	var orphans := Support.orphaned_after(store, 1, [10])
	assert_false(orphans.has(20), "pieces of building 2 are never orphaned by building 1")

func test_collapse_threshold() -> void:
	assert_true(Support.should_collapse(Support.COLLAPSE_THRESHOLD + 1), "over threshold collapses")
	assert_false(Support.should_collapse(1), "small orphan set does not collapse")

func test_collapse_at_exact_threshold_does_not_collapse() -> void:
	assert_false(Support.should_collapse(Support.COLLAPSE_THRESHOLD), "at threshold (>) does not collapse")

func test_nonstructural_does_not_transmit_support() -> void:
	var cat := PieceCatalog.load_file("res://pieces/pieces.json")
	var store := StructureStore.new(cat)
	var bcol := -1
	var brail := -1
	for i in cat.size():
		if cat.name_of(i) == "bcolumn": bcol = i
		if cat.name_of(i) == "brailing": brail = i
	# Foundation column at y=0; a railing (non-structural) stacked at y=1; a column at y=2
	# that only connects down THROUGH the railing.
	store.place(1, bcol,  Vector3i(0,0,0), 0, -1, 1)
	store.place(2, brail, Vector3i(0,1,0), 0, -1, 1)
	store.place(3, bcol,  Vector3i(0,2,0), 0, -1, 1)
	var orphans := Support.orphaned_after(store, 1, [])
	# The railing does not transmit support, so the top column (id 3) is orphaned even though a
	# railing bridges it to the foundation. The railing itself is adjacent to the surviving
	# foundation column (id 1) so it is NOT orphaned.
	assert_true(orphans.has(3), "top structural column orphaned (railing cannot support it)")
	assert_false(orphans.has(2), "railing kept (adjacent to surviving foundation column)")
	assert_false(orphans.has(1), "foundation column kept")

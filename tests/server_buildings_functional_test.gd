extends TestCase
## Deterministic destruction loop over StructureStore + Support, no networking, no bot AI.

func _cat() -> PieceCatalog:
	return PieceCatalog.load_file("res://pieces/pieces.json")

func _idx(cat: PieceCatalog, id: String) -> int:
	for i in cat.size():
		if cat.name_of(i) == id: return i
	return -1

func test_explosive_destroys_then_cascade_orphans() -> void:
	var cat := _cat()
	var store := StructureStore.new(cat)
	var bcol := _idx(cat, "bcolumn")
	store.place(1, bcol, Vector3i(0,0,0), 0, -1, 1)
	store.place(2, bcol, Vector3i(0,1,0), 0, -1, 1)
	store.place(3, bcol, Vector3i(0,2,0), 0, -1, 1)
	var center := BuildGrid.world_of(Vector3i(0,0,0))
	var res := store.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, center, 4.0)
	assert_true(res["destroyed"], "foundation column destroyed by explosive")
	var orphans := Support.orphaned_after(store, 1, [1])
	assert_eq(orphans.size(), 2, "the two columns above are orphaned")

func test_bullet_does_not_damage_building_piece() -> void:
	var cat := _cat()
	var store := StructureStore.new(cat)
	var bwall := _idx(cat, "bwall")
	store.place(1, bwall, Vector3i(0,0,0), 0, -1, 1)
	var center := BuildGrid.world_of(Vector3i(0,0,0))
	var res := store.damage_chunks(1, PieceCatalog.SRC_BULLET, center, 4.0)
	assert_false(res["hit"], "bullets cannot carve a building wall")

func test_cascade_scoped_to_one_building() -> void:
	var cat := _cat()
	var store := StructureStore.new(cat)
	var bcol := _idx(cat, "bcolumn")
	# Building 1: a 2-high stack. Building 2: an independent foundation piece.
	store.place(1, bcol, Vector3i(0,0,0), 0, -1, 1)
	store.place(2, bcol, Vector3i(0,1,0), 0, -1, 1)
	store.place(3, bcol, Vector3i(10,0,0), 0, -1, 2)
	store.remove(1)  # destroy building 1's foundation
	var orphans := Support.orphaned_after(store, 1, [1])
	assert_true(orphans.has(2), "building 1 upper piece orphaned")
	assert_false(orphans.has(3), "building 2 piece never orphaned by building 1's cascade")

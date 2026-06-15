extends TestCase
## A wall directly between two pawns must block the shot ray (no hit registered).

const CAT := '{"pieces":[{"id":"wall","height":"full","health":350,"blocks":"both"}]}'

func test_wall_between_blocks_shot() -> void:
	var store := StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])
	# Shooter eye at (0,1.5,0) aims +x at an enemy 10 m away; wall at x in [4,6].
	store.place(1, 0, Vector3i(2, 0, -1), 0, 99)   # cell (2,0,-1): x[4,6] y[0,2] z[-2,0]
	var origin := Vector3(0.0, 1.5, -1.0)
	var r := store.march(origin, Vector3(1, 0, 0), 50.0)
	assert_eq(r["hit"], true)
	assert_true(r["dist"] < 10.0, "wall is nearer than the 10m enemy")

func test_no_wall_does_not_block() -> void:
	var store := StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])
	assert_eq(store.march(Vector3(0.0, 1.5, -1.0), Vector3(1, 0, 0), 50.0)["hit"], false)

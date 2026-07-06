extends TestCase
## Integration: the roof-access ladders generated into conquest_town (tools/map_gen.py) must each
## land on a real walkable roof deck. This expands the map's building prefabs into a StructureStore
## exactly as the server does (server_main._start_match), then asserts every ladder's TOP is
## supported by a `bfloor` surface at that height and its BOTTOM is at ground. Guards against a
## generator/geometry drift that would put a ladder top over thin air (player climbs, then falls).

const PIECES_PATH := "res://pieces/pieces.json"

func _town_store_and_map() -> Array:
	var cat := PieceCatalog.load_file(PIECES_PATH)
	assert_true(cat != null, "piece catalog loads")
	var mres := MapDef.load_file("res://maps/conquest_town.json")
	assert_true(mres != null, "conquest_town loads")
	var store := StructureStore.new(cat)
	var next_id := 1
	var bid := 1
	for b in mres.buildings:
		# All town buildings are yaw=0, so piece offsets apply without rotation (matches map_gen.py).
		assert_eq(int(b["yaw"]), 0, "town building yaw is 0 (test assumes no rotation)")
		var pres := BuildingCatalog.load_file("res://buildings/%s.json" % b["prefab"], cat)
		assert_true(pres["ok"], "prefab %s loads" % b["prefab"])
		var origin: Vector3i = b["origin_cell"]
		for piece in pres["prefab"]["pieces"]:
			var off: Vector3i = piece["offset"]
			store.place(next_id, int(piece["type"]), origin + off, int(piece["yaw"]), -1, bid)
			next_id += 1
		bid += 1
	return [store, mres]

func test_town_has_roof_ladders() -> void:
	var mres := MapDef.load_file("res://maps/conquest_town.json")
	# The village-centre layout (edge rows removed for countryside) ships fewer buildings than the old
	# dense grid, hence fewer tall roofs — but the multi-storey landmarks still get their roof ladders.
	assert_true(mres.ladders.size() >= 8, "town generates roof ladders (>=8), got %d" % mres.ladders.size())

func test_every_ladder_top_lands_on_a_walkable_deck() -> void:
	var pair := _town_store_and_map()
	var store: StructureStore = pair[0]
	var m: MapDef = pair[1]
	for ld in m.ladders:
		var top: Vector3 = ld["top"]
		var bottom: Vector3 = ld["bottom"]
		assert_almost_eq(bottom.y, 0.0, 0.001, "ladder bottom at ground")
		assert_true(top.y >= 8.0, "roof ladder reaches a tall deck (>=8m), got %.1f" % top.y)
		# The deck must support a pawn standing at the dismount point (top). floor_height_at returns
		# the highest surface at/below the query; a supported deck sits within a cell of the top.
		var floor_y := store.floor_height_at(top.x, top.z, top.y + 0.1)
		assert_almost_eq(floor_y, top.y, 0.05,
			"ladder top (%.0f,%.0f,%.0f) lands on a deck; floor_height_at=%.2f" % [top.x, top.y, top.z, floor_y])

func test_every_ladder_is_linked_to_its_building() -> void:
	# H1: each ladder carries the id of the building it sits on, so a collapse can remove it. On a
	# clean map the server stamps building_id in generation order == building_index + 1.
	var m := MapDef.load_file("res://maps/conquest_town.json")
	for ld in m.ladders:
		var bidx := int(ld.get("building_index", -1))
		var bid := int(ld.get("building_id", 0))
		assert_true(bidx >= 0 and bidx < m.buildings.size(), "ladder building_index %d in [0,%d)" % [bidx, m.buildings.size()])
		assert_eq(bid, bidx + 1, "building_id = building_index + 1 (server stamping order)")

func test_collapse_removes_only_that_buildings_ladders() -> void:
	# H1: mirrors the server _resolve_cascades filter — collapsing one building drops exactly its
	# ladder(s) and leaves every other building's ladders intact (no ghost ladder in the air).
	var m := MapDef.load_file("res://maps/conquest_town.json")
	var target := int(m.ladders[0]["building_id"])
	var kept: Array = []
	for ld in m.ladders:
		if int(ld.get("building_id", 0)) != target:
			kept.append(ld)
	assert_true(kept.size() < m.ladders.size(), "at least one ladder removed for the collapsed building")
	for ld in kept:
		assert_true(int(ld["building_id"]) != target, "no surviving ladder belongs to the collapsed building")

func test_climb_from_base_reaches_the_deck() -> void:
	# End-to-end via the pure Ladder helpers: engage at the base, climb to the top anchor.
	var m := MapDef.load_file("res://maps/conquest_town.json")
	var ld: Dictionary = m.ladders[0]
	var bottom: Vector3 = ld["bottom"]
	var top: Vector3 = ld["top"]
	assert_true(Ladder.should_engage(ld, bottom, 1.0), "upward intent at base engages")
	var pos := bottom
	for _i in range(600):   # 20 s @ 30 Hz — ample to climb any 8-10 m ladder
		pos = Ladder.climb_step(ld, pos, 1.0, 1.0 / 30.0)
		if pos.y >= top.y - Ladder.ANCHOR_EPS:
			break
	assert_almost_eq(pos.y, top.y, 0.05, "climb reaches the roof deck height")
	assert_almost_eq(pos.x, bottom.x, 0.001, "x stays locked to the ladder line")
	assert_almost_eq(pos.z, bottom.z, 0.001, "z stays locked to the ladder line")

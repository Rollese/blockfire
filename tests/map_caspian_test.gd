extends TestCase
## Deterministic validation of the generated conquest_caspian map.
## Run: godot --headless --path . -- --test --filter=caspian

func _map() -> MapDef:
	return MapDef.load_file("res://maps/conquest_caspian.json")

func test_map_loads() -> void:
	var m := _map()
	assert_true(m != null, "conquest_caspian.json loads + validates")
	assert_eq(m.world_half, 500.0)

func test_five_flags_with_ownership() -> void:
	var m := _map()
	assert_eq(m.points.size(), 5, "five capture points")
	var by_id := {}
	for p in m.points:
		by_id[p["id"]] = p
	for id in ["A", "B", "C", "D", "E"]:
		assert_true(by_id.has(id), "flag %s present" % id)
	assert_eq(by_id["A"]["start_owner"], 0, "A owned by US")
	assert_eq(by_id["B"]["start_owner"], 0, "B owned by US")
	assert_eq(by_id["C"]["start_owner"], -1, "C neutral")
	assert_eq(by_id["D"]["start_owner"], 1, "D owned by RU")
	assert_eq(by_id["E"]["start_owner"], 1, "E owned by RU")

func test_two_team_bases() -> void:
	var m := _map()
	assert_false(m.base_for(0).is_empty(), "US base present")
	assert_false(m.base_for(1).is_empty(), "RU base present")
	assert_true(m.base_for(0)["pos"].z < 0.0, "US deploys north")
	assert_true(m.base_for(1)["pos"].z > 0.0, "RU deploys south")

func test_no_vehicle_spawns() -> void:
	var m := _map()
	assert_eq(m.vehicle_spawns.size(), 0, "vehicles deferred (AGENTS.md §12)")

func test_has_terrain_block() -> void:
	var m := _map()
	assert_true(m.terrain.has("heightmap"), "map declares a heightmap")
	assert_eq(m.terrain["heightmap"], "heightmaps/conquest_caspian.png")
	assert_true(m.terrain.has("surface_map"), "map paints roads via a splatmap")
	assert_true(float(m.terrain["height_scale"]) > 0.0, "non-zero relief")

func test_terrain_grid_loads() -> void:
	var m := _map()
	var grid := Terrain.load_for_map(m, "res://maps", Callable())
	assert_true(grid != null, "Terrain builds from the heightmap")
	var h_hill := Terrain.height_at(grid, -45.0, 74.0)
	var h_base := Terrain.height_at(grid, -34.0, -375.0)
	assert_true(h_hill > h_base, "Hilltop rises above the northern base")

func test_has_buildings_at_flags() -> void:
	var m := _map()
	assert_true(m.buildings.size() >= 8, "flags/bases have structures")
	for b in m.buildings:
		assert_true(b.has("footprint"), "%s has a baked footprint" % b["prefab"])

func test_gas_station_prefab_present() -> void:
	var m := _map()
	var names := []
	for b in m.buildings:
		names.append(b["prefab"])
	assert_true(names.has("gas_station"), "Gas Station uses the gas_station prefab")

func test_border_wall_spans_with_openings() -> void:
	var m := _map()
	var border_cz := int(round(0.0 / 2.4))
	var xs := []
	for pb in m.prebuilt:
		if pb["type"] == "bwall" and int(pb["cell"].z) == border_cz:
			xs.append(int(pb["cell"].x))
	assert_true(xs.size() > 40, "wall is a long run of blocks (got %d)" % xs.size())
	xs.sort()
	var gaps := 0
	for i in range(1, xs.size()):
		if xs[i] - xs[i - 1] >= 4:
			gaps += 1
	assert_true(gaps >= 3, "wall has >=3 openings (crossing+gate+breach), got %d" % gaps)

func test_wall_has_barbed_wire_cap() -> void:
	var m := _map()
	var has_rail := false
	for pb in m.prebuilt:
		if pb["type"] == "brailing":
			has_rail = true
			break
	assert_true(has_rail, "wall is capped with brailing (barbed wire)")

func test_road_crossings_are_open_in_wall() -> void:
	# No road that crosses the border line (z=0) may be blocked by wall pieces.
	var m := _map()
	var border_cz := int(round(0.0 / 2.4))
	var wall_x := {}
	for pb in m.prebuilt:
		if pb["type"] == "bwall" and int(pb["cell"].z) == border_cz:
			wall_x[int(pb["cell"].x)] = true
	for rd in m.roads:
		if rd["min"].z <= 0.0 and rd["max"].z >= 0.0:
			var cx0 := int(ceil(rd["min"].x / 2.4))    # cells fully inside the road span
			var cx1 := int(floor(rd["max"].x / 2.4))
			for cx in range(cx0, cx1 + 1):
				assert_false(wall_x.has(cx), "road crossing at cell x=%d is walled shut" % cx)

func test_antenna_has_climbable_vantage() -> void:
	var m := _map()
	assert_true(m.ladders.size() >= 1, "Antenna has a ladder")
	assert_true(m.platforms.size() >= 1, "Antenna has a platform deck")
	var lad = m.ladders[0]
	assert_true(lad["top"].y > lad["bottom"].y + 3.0, "ladder climbs >3 m")

func test_has_scenery() -> void:
	var m := _map()
	assert_true(m.scenery.size() >= 20, "forest + rocks placed (got %d)" % m.scenery.size())
	var kinds := {"tree": 0, "rock": 0}
	for s in m.scenery:
		if String(s["id"]).begins_with("tree"): kinds["tree"] += 1
		if String(s["id"]).begins_with("rock"): kinds["rock"] += 1
	assert_true(kinds["tree"] > 0 and kinds["rock"] > 0, "both trees and rocks present")

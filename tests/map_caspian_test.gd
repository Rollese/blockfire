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

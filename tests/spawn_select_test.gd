extends TestCase

func _map() -> MapDef:
	var json := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'
	return MapDef.from_json_string(json)["map"]

func test_spawns_at_home_base_when_no_points_owned() -> void:
	var m := _map()
	var pos := SpawnSelect.select(0, m, ConquestState.new(m), [], Vector3(100, 0, 0))
	assert_true(pos.distance_to(Vector3(-900, 0, 0)) <= SpawnSelect.JITTER * 1.5, "near home base")

func test_prefers_owned_point_near_objective() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	c.points[0]["owner"] = 0   # team 0 owns A at (100,0,0)
	var pos := SpawnSelect.select(0, m, c, [], Vector3(100, 0, 0))
	assert_true(pos.distance_to(Vector3(100, 0, 0)) <= SpawnSelect.JITTER * 1.5, "spawns on owned point near objective")

func test_never_spawns_on_enemy_point() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	c.points[0]["owner"] = 1   # enemy owns A
	var pos := SpawnSelect.select(0, m, c, [], Vector3(100, 0, 0))
	assert_true(pos.distance_to(Vector3(-900, 0, 0)) <= SpawnSelect.JITTER * 1.5, "falls back to home, never enemy point")

func test_spawns_on_squadmate() -> void:
	var m := _map()
	var pos := SpawnSelect.select(0, m, ConquestState.new(m), [Vector3(50, 0, 50)], Vector3(50, 0, 50))
	assert_true(pos.distance_to(Vector3(50, 0, 50)) <= SpawnSelect.JITTER * 1.5, "spawns near squadmate")

func test_jitter_within_bounds_and_grounded() -> void:
	var m := _map()
	var pos := SpawnSelect.select(0, m, ConquestState.new(m), [], Vector3(-900, 0, 0))
	assert_almost_eq(pos.y, 0.0, 0.001, "spawns grounded")
	assert_true(absf(pos.x - (-900.0)) <= SpawnSelect.JITTER, "x jitter bounded")

func test_skips_owned_point_contested_by_enemy() -> void:
	var m := _map()                     # point A at (100,0,0); home base at (-900,0,0)
	var c := ConquestState.new(m)
	c.points[0]["owner"] = 0            # team 0 owns A
	c.points[0]["n1"] = 1              # ...but an enemy is on it (as step() would cache)
	var pos := SpawnSelect.select(0, m, c, [], Vector3(100, 0, 0))
	assert_true(pos.distance_to(Vector3(-900, 0, 0)) <= SpawnSelect.JITTER * 1.5,
		"contested owned point is skipped -> falls back to home base (no spawning on a contested flag)")

# --- Task 4: choose() with FOB source + chosen-kind ---

func _m() -> MapDef:
	# MapDef requires at least one point; use a far neutral point so it is never an owned source.
	var json := '{"points":[{"id":"X","pos":[0,0,500],"radius":15,"start_owner":-1}],"bases":[{"team":0,"pos":[-100,0,0],"radius":10},{"team":1,"pos":[100,0,0],"radius":10}]}'
	return MapDef.from_json_string(json)["map"]

func _c(m: MapDef) -> ConquestState:
	return ConquestState.new(m)

func test_choose_prefers_nearest_fob_over_far_base() -> void:
	var m := _m()
	var c := _c(m)
	var objective := Vector3(20, 0, 0)
	# FOB at (15,0,0) is far nearer the objective than the base at (-100,0,0).
	var r := SpawnSelect.choose(0, m, c, [], objective, [Vector3(15, 0, 0)])
	assert_eq(r["kind"], SpawnSelect.SRC_FOB, "the nearer FOB is chosen")

func test_choose_base_when_no_other_source() -> void:
	var m := _m()
	var c := _c(m)
	var r := SpawnSelect.choose(0, m, c, [], Vector3(20, 0, 0), [])
	assert_eq(r["kind"], SpawnSelect.SRC_BASE, "base is the fallback source")

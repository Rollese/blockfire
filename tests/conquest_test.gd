extends TestCase

func _map_one_point(radius := 30.0, start_owner := -1) -> MapDef:
	var json := '{"points":[{"id":"A","pos":[0,0,0],"radius":%f,"start_owner":%d}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}' % [radius, start_owner]
	return MapDef.from_json_string(json)["map"]

func _world_with(team_positions: Array) -> World:
	# team_positions: Array of [team:int, pos:Vector3]
	var w := World.new()
	var id := 1
	for tp in team_positions:
		var p := w.spawn(id)
		p.team = tp[0]; p.pos = tp[1]; p.alive = true
		id += 1
	return w

func test_neutral_point_captured_in_one_phase() -> void:
	var c := ConquestState.new(_map_one_point())
	var w := _world_with([[0, Vector3.ZERO]])
	for i in 110: c.step(0.1, w)   # ~11s, base rate 0.10 -> captured by 10s
	assert_eq(c.points[0]["owner"], 0, "team 0 captured the neutral point")

func test_enemy_point_needs_neutralize_then_capture() -> void:
	var c := ConquestState.new(_map_one_point(30.0, 1))  # starts owned by team 1
	var w := _world_with([[0, Vector3.ZERO]])
	for i in 110: c.step(0.1, w)
	assert_eq(c.points[0]["owner"], -1, "neutralized first (not yet team 0)")
	for i in 110: c.step(0.1, w)
	assert_eq(c.points[0]["owner"], 0, "then captured")

func test_contested_freezes_progress() -> void:
	var c := ConquestState.new(_map_one_point())
	var w := _world_with([[0, Vector3.ZERO], [1, Vector3.ZERO]])
	for i in 200: c.step(0.1, w)
	assert_eq(c.points[0]["owner"], -1, "contested stays neutral")
	assert_almost_eq(c.points[0]["cap"], 0.0, 0.001)

func test_more_attackers_capture_faster() -> void:
	var c1 := ConquestState.new(_map_one_point())
	var c8 := ConquestState.new(_map_one_point())
	var many := []
	for i in 8: many.append([0, Vector3.ZERO])
	for i in 20:
		c1.step(0.1, _world_with([[0, Vector3.ZERO]]))
		c8.step(0.1, _world_with(many))
	assert_true(c8.points[0]["cap"] > c1.points[0]["cap"], "8 attackers progress faster")

func test_empty_point_decays() -> void:
	var c := ConquestState.new(_map_one_point())
	for i in 30: c.step(0.1, _world_with([[0, Vector3.ZERO]]))
	var mid: float = c.points[0]["cap"]
	assert_true(mid > 0.0)
	for i in 50: c.step(0.1, World.new())
	assert_true(c.points[0]["cap"] < mid, "decays when empty")

func test_bleed_by_flag_deficit() -> void:
	var c := ConquestState.new(_map_one_point(30.0, 0))  # team 0 owns the only point
	var t1_before: float = c.tickets[1]
	for i in 10: c.step(1.0, World.new())  # 10s, team 1 deficit = 1
	assert_true(c.tickets[1] < t1_before, "losing team bleeds")
	assert_almost_eq(c.tickets[0], float(ConquestState.TICKETS_START), 0.001, "winning team doesn't bleed")

func test_death_costs_ticket() -> void:
	var c := ConquestState.new(_map_one_point())
	c.register_death(1)
	assert_eq(c.tickets_int(1), ConquestState.TICKETS_START - 1)

func test_win_at_zero_tickets() -> void:
	var c := ConquestState.new(_map_one_point())
	c.tickets[1] = 0.5
	c.register_death(1)            # -> <= 0
	c.step(0.001, World.new())
	assert_true(c.match_over)
	assert_eq(c.winner, 0, "team 0 wins when team 1 hits 0")

func test_nearest_capturable_skips_owned() -> void:
	var json := '{"points":[{"pos":[0,0,0],"radius":10,"start_owner":0},{"pos":[100,0,0],"radius":10,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":1},{"team":1,"pos":[900,0,0],"radius":1}]}'
	var c := ConquestState.new(MapDef.from_json_string(json)["map"])
	assert_eq(c.nearest_capturable_index(0, Vector3(5, 0, 0)), 1, "skips the point team 0 already owns")

func test_point_contested_by_enemy_tracks_presence() -> void:
	var c := ConquestState.new(_map_one_point(30.0, 0))   # team 0 owns A at origin
	c.step(0.1, _world_with([[1, Vector3.ZERO]]))         # a team-1 enemy stands on it
	assert_true(c.point_contested_by_enemy(0, 0), "team 0's point is contested by the enemy on it")
	assert_false(c.point_contested_by_enemy(1, 0), "the enemy's own presence is not a contest for it")

func test_point_not_contested_when_empty_or_friendly_only() -> void:
	var c := ConquestState.new(_map_one_point(30.0, 0))
	c.step(0.1, World.new())
	assert_false(c.point_contested_by_enemy(0, 0), "empty point is not contested")
	c.step(0.1, _world_with([[0, Vector3.ZERO]]))         # only a friendly present
	assert_false(c.point_contested_by_enemy(0, 0), "friendly-only presence is not a contest")

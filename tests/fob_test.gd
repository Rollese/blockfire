extends TestCase

## Two bases + one capture point at the origin. `pt_owner` = the point's start_owner
## (-1 neutral / 0 us / 1 enemy). ConquestState._init requires the start_owner key, so build
## the map via from_json_string (the canonical path; a bare MapDef.new() omits it).
func _map(pt_owner := -1) -> MapDef:
	var json := '{"points":[{"id":"A","pos":[0,0,0],"radius":15,"start_owner":%d}],"bases":[{"team":0,"pos":[-100,0,0],"radius":10},{"team":1,"pos":[100,0,0],"radius":10}]}' % pt_owner
	return MapDef.from_json_string(json)["map"]

func _conq(m: MapDef) -> ConquestState:
	return ConquestState.new(m)   # constructor takes the MapDef (no separate configure)

func test_placement_ok_in_open_ground() -> void:
	var m := _map(-1)   # point neutral
	var c := _conq(m)
	assert_true(Fob.placement_ok(Vector3(-40, 0, 0), 0, m, c), "open friendly-side ground is valid")

func test_placement_blocked_inside_enemy_point_radius() -> void:
	var m := _map(1)    # point owned by enemy (team 1)
	var c := _conq(m)
	# 10 m from the point centre, well inside its 15 m radius.
	assert_false(Fob.placement_ok(Vector3(10, 0, 0), 0, m, c), "cannot place inside an enemy-owned CP radius")

func test_placement_blocked_inside_enemy_base() -> void:
	var m := _map(-1)
	var c := _conq(m)
	assert_false(Fob.placement_ok(Vector3(105, 0, 5), 0, m, c), "cannot place inside the enemy home base")

func test_placement_ok_inside_own_point() -> void:
	var m := _map(0)    # point owned by us
	var c := _conq(m)
	assert_true(Fob.placement_ok(Vector3(5, 0, 0), 0, m, c), "our own CP is fine")

func test_spawn_enabled_when_no_enemy_near() -> void:
	assert_true(Fob.spawn_enabled(Vector3.ZERO, [Vector3(100, 0, 0)]), "enemy 100 m away -> enabled")

func test_spawn_disabled_when_enemy_inside_vicinity() -> void:
	# Enemy 39 m away on XZ (just inside 40 m), with a big Y offset that must be ignored (planar).
	assert_false(Fob.spawn_enabled(Vector3.ZERO, [Vector3(39, 50, 0)]), "enemy within XZ vicinity -> disabled")

func test_spawn_enable_boundary_just_outside() -> void:
	assert_true(Fob.spawn_enabled(Vector3.ZERO, [Vector3(41, 0, 0)]), "just outside vicinity -> enabled")

func test_leader_is_lowest_id_in_squad() -> void:
	# visible = ids the inferring bot can see in its squad (incl. self). Leader = min id.
	assert_true(Fob.is_squad_leader(7, [7, 12, 30]), "lowest id is the leader")
	assert_false(Fob.is_squad_leader(12, [7, 12, 30]), "non-min id is not the leader")
	assert_true(Fob.is_squad_leader(7, [7]), "sole member is its own leader")

extends TestCase
## M8-P3: map rotation — at match end + drain the server resets ALL match state and
## starts the next map in the rotation instead of exiting. Uses the real server
## (fixture, SpyNet — no ENet) and real _start_match/_rotate_match.

const F := preload("res://tests/server_fixture.gd")


func _rotating_server():
	var srv = F.make_server()
	srv._maps = ["conquest_dev_arena", "conquest_proving_grounds"]
	srv._map_index = 0
	srv._rotate = true
	srv._map_path = "res://maps/conquest_dev_arena.json"
	# Boot-scoped catalogs _start_match needs beyond the fixture's piece catalog:
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	srv._attachments = Attachment.load_file("res://data/attachments.json")
	srv._vehicles_cat = VehicleCatalog.load_file("res://data/vehicles.json")
	assert_true(srv._start_match())
	return srv


func test_rotate_advances_map_and_resets_state() -> void:
	var srv = _rotating_server()
	autofree(srv)
	# Dirty every category of match state a real match touches.
	F.add_client(srv, 7, 0)
	F.add_pawn(srv, 7, 0, Vector3(1, 0, 1))
	srv._team_counts[0] = 1
	srv._grenades.append({"owner": 7})
	srv._smoke_zones.append({"pos": Vector3.ZERO, "radius": 6.0, "expire_tick": 999})
	srv._stats.kills = 5
	srv._degrade_level = 2
	srv._match_over_broadcast = true
	srv._match_end_tick = 100
	srv._sim.tick = 500

	srv._rotate_match()

	assert_eq(srv._map_index, 1)
	assert_eq(srv._map_path, "res://maps/conquest_proving_grounds.json")
	assert_eq(srv._map.name, "proving_grounds")
	assert_eq(srv._clients.size(), 0)
	assert_eq(srv._sim.world.pawns.size(), 0)
	assert_eq(srv._sim.tick, 0)
	assert_eq(srv._grenades.size(), 0)
	assert_eq(srv._smoke_zones.size(), 0)
	assert_eq(srv._stats.kills, 0)                          # fresh ServerStats
	assert_eq(srv._degrade_level, 0)
	assert_false(srv._match_over_broadcast)
	assert_eq(srv._match_end_tick, -1)
	assert_eq(srv._team_counts, {0: 0, 1: 0})
	assert_true(srv._store.count() > 0)                     # new map's structures stamped
	assert_false(srv._conquest.match_over)                  # fresh conquest


func test_rotate_wraps_to_first_map() -> void:
	var srv = _rotating_server()
	autofree(srv)
	srv._map_index = 1
	srv._map_path = "res://maps/conquest_proving_grounds.json"
	assert_true(srv._start_match())
	srv._rotate_match()
	assert_eq(srv._map_index, 0)
	assert_eq(srv._map_path, "res://maps/conquest_dev_arena.json")


func test_vehicles_respawn_fresh_on_rotation() -> void:
	var srv = _rotating_server()
	autofree(srv)
	var v_before: int = srv._sim.world.vehicles.size()
	srv._rotate_match()
	assert_true(srv._sim.world.vehicles.size() > 0 or v_before == 0)
	for vid in srv._sim.world.vehicles:
		var v: Vehicle = srv._sim.world.vehicles[vid]
		assert_true(v.hp > 0)

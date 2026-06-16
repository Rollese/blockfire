extends TestCase

func _vs(pos: Vector3, team_seat0: int) -> VehicleState:
	var s := VehicleState.new(); s.pos = pos; s.hp = 1000; s.type = 0
	s.seats = [team_seat0, 0, 0, 0, 0]; return s

func test_nearest_free_own_vehicle_picks_closest_with_a_free_seat() -> void:
	var vview := {
		Vehicle.id_for(0): _vs(Vector3(100, 0, 0), 0),   # far
		Vehicle.id_for(1): _vs(Vector3(5, 0, 0), 0),     # near, has free seats
	}
	var got := BotDriver.nearest_free_vehicle(vview, Vector3.ZERO)
	assert_eq(got, Vehicle.id_for(1))

func test_nearest_free_vehicle_skips_full() -> void:
	var full := VehicleState.new(); full.pos = Vector3(2, 0, 0); full.seats = [1, 2, 3, 4, 5]
	var vview := {Vehicle.id_for(0): full}
	assert_eq(BotDriver.nearest_free_vehicle(vview, Vector3.ZERO), 0)

func test_drive_dir_points_at_objective() -> void:
	# steering toward an objective to the +x returns positive throttle-forward intent
	var cmd := BotDriver.drive_toward(0.0, Vector3.ZERO, Vector3(50, 0, 0))
	assert_true(float(cmd["move_y"]) > 0.0)

func test_drive_toward_steers_right_to_face_target() -> void:
	# facing +Z (heading 0), target to the +X: needs positive steer to rotate the nose toward it
	var c := BotDriver.drive_toward(0.0, Vector3.ZERO, Vector3(50, 0, 0))
	assert_true(float(c["move_x"]) > 0.0)

func test_drive_toward_no_steer_when_aligned() -> void:
	# facing +Z (heading 0), target straight ahead on +Z: ~no steer
	var c := BotDriver.drive_toward(0.0, Vector3.ZERO, Vector3(0, 0, 50))
	assert_almost_eq(float(c["move_x"]), 0.0, 0.01)

func test_drive_toward_steers_left_for_target_behind_left() -> void:
	# facing +Z, target to -X: negative steer
	var c := BotDriver.drive_toward(0.0, Vector3.ZERO, Vector3(-50, 0, 0))
	assert_true(float(c["move_x"]) < 0.0)

func test_vehicle_is_enemy_true_when_enemy_occupant() -> void:
	var v := VehicleState.new(); v.seats = [42, 0, 0, 0, 0]
	var enemy := EntityState.new(); enemy.team = 1
	var view := {42: enemy}
	assert_true(BotDriver.vehicle_is_enemy(v, view, 0))   # my_team 0, occupant team 1 -> enemy

func test_vehicle_is_enemy_false_when_friendly_or_empty() -> void:
	var v := VehicleState.new(); v.seats = [42, 0, 0, 0, 0]
	var friendly := EntityState.new(); friendly.team = 0
	assert_false(BotDriver.vehicle_is_enemy(v, {42: friendly}, 0))   # same team
	var empty := VehicleState.new(); empty.seats = [0, 0, 0, 0, 0]
	assert_false(BotDriver.vehicle_is_enemy(empty, {}, 0))           # empty

func test_nearest_enemy_vehicle_picks_closest_enemy_in_range() -> void:
	var near := VehicleState.new(); near.pos = Vector3(10, 0, 0); near.seats = [7, 0, 0, 0, 0]
	var far := VehicleState.new(); far.pos = Vector3(50, 0, 0); far.seats = [8, 0, 0, 0, 0]
	var e7 := EntityState.new(); e7.team = 1
	var e8 := EntityState.new(); e8.team = 1
	var vview := {Vehicle.id_for(0): near, Vehicle.id_for(1): far}
	var view := {7: e7, 8: e8}
	assert_eq(BotDriver.nearest_enemy_vehicle(vview, view, Vector3.ZERO, 0, 60.0), Vehicle.id_for(0))

func test_nearest_enemy_vehicle_zero_when_out_of_range() -> void:
	var v := VehicleState.new(); v.pos = Vector3(200, 0, 0); v.seats = [7, 0, 0, 0, 0]
	var e := EntityState.new(); e.team = 1
	assert_eq(BotDriver.nearest_enemy_vehicle({Vehicle.id_for(0): v}, {7: e}, Vector3.ZERO, 0, 60.0), 0)

func test_enemy_spawn_pos_returns_other_team_spawn() -> void:
	var spawns := [
		{"team": 0, "pos": Vector3(-900, 0, 0)},
		{"team": 1, "pos": Vector3(900, 0, 0)},
	]
	assert_eq(BotDriver.enemy_spawn_pos(spawns, 0, Vector3.ZERO), Vector3(900, 0, 0))
	assert_eq(BotDriver.enemy_spawn_pos(spawns, 1, Vector3.ZERO), Vector3(-900, 0, 0))

func test_enemy_spawn_pos_falls_back_when_none() -> void:
	assert_eq(BotDriver.enemy_spawn_pos([], 0, Vector3(5, 0, 5)), Vector3(5, 0, 5))

func test_central_point_index_picks_nearest_origin() -> void:
	var pts := [Vector3(-600, 0, -400), Vector3(0, 0, 0), Vector3(600, 0, 400)]
	assert_eq(BotDriver.central_point_index(pts), 1)

func test_central_point_index_empty_is_negative() -> void:
	assert_eq(BotDriver.central_point_index([]), -1)

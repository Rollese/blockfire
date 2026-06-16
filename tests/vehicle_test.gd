extends TestCase

func _def() -> Dictionary:
	return VehicleCatalog.load_file("res://data/vehicles.json").def_of(0)

func _veh() -> Vehicle:
	return Vehicle.make(Vehicle.id_for(0), 0, _def(), 1, Vector3(10, 0, 5))

func test_make_copies_stats_and_seats() -> void:
	var v := _veh()
	assert_eq(v.hp, 600)
	assert_eq(v.max_hp, 600)
	assert_eq(v.team, 1)
	assert_eq(v.seat_count(), 5)
	assert_true(v.alive)

func test_id_for_is_in_disjoint_range() -> void:
	assert_true(Vehicle.id_for(0) >= Vehicle.ID_BASE)

func test_seat_world_at_zero_heading_adds_offset() -> void:
	var v := _veh()
	v.heading = 0.0
	# driver offset [0,1,1.6] -> +z is forward; pos (10,0,5) -> (10,1,6.6)
	var w := v.seat_world(0)
	assert_almost_eq(w.x, 10.0, 0.001)
	assert_almost_eq(w.y, 1.0, 0.001)
	assert_almost_eq(w.z, 6.6, 0.001)

func test_seat_world_rotates_with_heading() -> void:
	var v := _veh()
	v.heading = PI / 2.0   # forward -> +x
	# driver offset z=1.6 forward maps to +x
	var w := v.seat_world(0)
	assert_almost_eq(w.x, 11.6, 0.001)
	assert_almost_eq(w.z, 5.0, 0.001)

func test_free_seat_prefers_hint_then_first_empty() -> void:
	var v := _veh()
	assert_eq(v.free_seat(2), 2)
	v.seats[2] = 99
	assert_eq(v.free_seat(2), 0)   # hint taken -> first empty
	for s in v.seat_count(): v.seats[s] = 1
	assert_eq(v.free_seat(0), -1)  # full

func test_can_enter_requires_team_alive_range_and_unseated() -> void:
	var v := _veh()
	var p := Pawn.new(7); p.team = 1; p.alive = true
	assert_true(Vehicle.can_enter(v, p, 2.0, 3.0))
	assert_false(Vehicle.can_enter(v, p, 5.0, 3.0))   # out of range
	p.team = 0
	assert_false(Vehicle.can_enter(v, p, 2.0, 3.0))   # wrong team
	p.team = 1; p.in_vehicle = 999
	assert_false(Vehicle.can_enter(v, p, 2.0, 3.0))   # already seated

func test_to_state_mirrors_fields() -> void:
	var v := _veh()
	v.hp = 700; v.heading = 0.3; v.turret_yaw = -0.2; v.seats[0] = 7
	var s := v.to_state()
	assert_eq(s.hp, 700)
	assert_eq(s.type, 0)
	assert_almost_eq(s.turret_yaw, -0.2, 0.0001)
	assert_eq(int(s.seats[0]), 7)

func test_accelerates_forward_and_clamps_to_max_speed() -> void:
	var v := _veh(); v.heading = 0.0
	for _i in 600:
		v.step(1.0 / 30.0, {"move_y": 1.0, "move_x": 0.0})
	assert_almost_eq(v.speed, v.max_speed, 0.01)   # clamped, not exceeded

func test_no_pivot_at_standstill() -> void:
	var v := _veh(); v.heading = 0.0; v.speed = 0.0
	v.step(1.0 / 30.0, {"move_y": 0.0, "move_x": 1.0})
	assert_almost_eq(v.heading, 0.0, 0.0001)   # turn_factor(0) == 0

func test_turns_while_moving() -> void:
	var v := _veh(); v.heading = 0.0; v.speed = v.max_speed
	v.step(1.0 / 30.0, {"move_y": 1.0, "move_x": 1.0})
	assert_true(v.heading > 0.0)

func test_drag_decelerates_when_coasting() -> void:
	var v := _veh(); v.speed = 10.0; v.heading = 0.0
	v.step(1.0 / 30.0, {"move_y": 0.0, "move_x": 0.0})
	assert_true(v.speed < 10.0)

func test_physics_is_deterministic() -> void:
	var a := _veh(); var b := _veh()
	var cmds := [{"move_y": 1.0, "move_x": 0.3}, {"move_y": 1.0, "move_x": -0.2}, {"move_y": 0.5, "move_x": 0.0}]
	for _r in 50:
		for cmd in cmds:
			a.step(1.0 / 30.0, cmd); b.step(1.0 / 30.0, cmd)
	assert_almost_eq(a.pos.x, b.pos.x, 0.0001)
	assert_almost_eq(a.pos.z, b.pos.z, 0.0001)
	assert_almost_eq(a.heading, b.heading, 0.0001)

func test_clamps_to_world_bounds() -> void:
	var v := _veh(); v.pos = Vector3(Vehicle.WORLD_HALF - 0.1, 0, 0); v.heading = PI / 2.0
	for _i in 60:
		v.step(1.0 / 30.0, {"move_y": 1.0, "move_x": 0.0})
	assert_true(v.pos.x <= Vehicle.WORLD_HALF + 0.0001)

func test_exit_world_pos_is_beside_hull() -> void:
	var v := _veh(); v.heading = 0.0; v.pos = Vector3(0, 0, 0)
	# exit_offset [2.5,0,0] (right side) at heading 0 -> +x
	var w := v.seat_world(0)   # sanity: seat geometry exists
	assert_true(w != null)
	var exit := v.pos + Vehicle.rotate_yaw(v.exit_offset, v.heading)
	assert_almost_eq(exit.x, 2.5, 0.001)
	assert_almost_eq(exit.z, 0.0, 0.001)

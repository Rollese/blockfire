extends TestCase

func _sim_with_vehicle() -> SimLoop:
	var sim := SimLoop.new()
	var def := VehicleCatalog.load_file("res://data/vehicles.json").def_of(0)
	var v := Vehicle.make(Vehicle.id_for(0), 0, def, 1, Vector3(0, 0, 0))
	sim.world.spawn_vehicle(v)
	return sim

func test_step_vehicles_integrates_driver_input() -> void:
	var sim := _sim_with_vehicle()
	var vid := Vehicle.id_for(0)
	for _i in 30:
		sim.step_vehicles({vid: {"move_y": 1.0, "move_x": 0.0}})
	assert_true((sim.world.vehicles[vid] as Vehicle).speed > 0.0)

func test_seated_occupant_pos_tracks_seat() -> void:
	var sim := _sim_with_vehicle()
	var vid := Vehicle.id_for(0)
	var v: Vehicle = sim.world.vehicles[vid]
	var p := sim.world.spawn(7); p.team = 1; p.in_vehicle = vid; p.seat = 0
	v.seats[0] = 7
	v.pos = Vector3(5, 0, 5)
	sim.step_vehicles({})
	assert_almost_eq(p.pos.x, v.seat_world(0).x, 0.001)
	assert_almost_eq(p.pos.z, v.seat_world(0).z, 0.001)

func test_seated_pawn_step_does_not_self_move() -> void:
	var p := Pawn.new(7); p.in_vehicle = 123; p.pos = Vector3(2, 0, 2)
	p.step(1.0 / 30.0, {"move_x": 1.0, "move_y": 1.0})
	assert_almost_eq(p.pos.x, 2.0, 0.001)   # position owned by the vehicle, not its own step
	assert_almost_eq(p.pos.z, 2.0, 0.001)

func test_gunner_turret_yaw_follows_gunner_look() -> void:
	var sim := _sim_with_vehicle()
	var vid := Vehicle.id_for(0)
	var v: Vehicle = sim.world.vehicles[vid]
	var g := sim.world.spawn(9); g.team = 1; g.in_vehicle = vid; g.seat = 4; g.yaw = 1.234
	v.seats[4] = 9
	sim.step_vehicles({})
	assert_almost_eq(v.turret_yaw, 1.234, 0.001)

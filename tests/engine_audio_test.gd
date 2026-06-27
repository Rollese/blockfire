extends TestCase

func _veh(pos: Vector3, hp: int, driver: int) -> VehicleState:
	var v := VehicleState.new()
	v.pos = pos
	v.hp = hp
	v.seats = [driver, 0, 0]   # seat 0 = driver occupant id (0 = empty)
	return v

func test_no_running_vehicles_returns_not_found() -> void:
	var vs := {100: _veh(Vector3(5, 0, 0), 600, 0)}   # alive but driverless
	var r := EngineAudio.nearest_running(vs, Vector3.ZERO, -1, 200.0)
	assert_false(r["found"], "a driverless vehicle is not running")

func test_driver_seated_vehicle_runs() -> void:
	var vs := {100: _veh(Vector3(5, 0, 0), 600, 7)}   # driver pawn 7 seated
	var r := EngineAudio.nearest_running(vs, Vector3.ZERO, -1, 200.0)
	assert_true(r["found"], "driver-occupied vehicle runs")
	assert_eq(r["pos"], Vector3(5, 0, 0), "voices the running vehicle's position")

func test_own_vehicle_runs_even_as_passenger() -> void:
	var vs := {100: _veh(Vector3(9, 0, 0), 600, 0)}   # no driver, but it's MY vehicle (riding it)
	var r := EngineAudio.nearest_running(vs, Vector3.ZERO, 100, 200.0)
	assert_true(r["found"], "you hear your own engine even with no driver record")

func test_wrecked_vehicle_does_not_run() -> void:
	var vs := {100: _veh(Vector3(3, 0, 0), 0, 7)}   # hp 0 (destroyed) though driver seated
	var r := EngineAudio.nearest_running(vs, Vector3.ZERO, 100, 200.0)
	assert_false(r["found"], "a wrecked vehicle's engine is dead")

func test_out_of_range_is_ignored() -> void:
	var vs := {100: _veh(Vector3(500, 0, 0), 600, 7)}
	var r := EngineAudio.nearest_running(vs, Vector3.ZERO, -1, 200.0)
	assert_false(r["found"], "beyond max_dist -> not voiced")

func test_picks_nearest_of_several_running() -> void:
	var vs := {
		100: _veh(Vector3(50, 0, 0), 600, 7),
		101: _veh(Vector3(10, 0, 0), 600, 8),
		102: _veh(Vector3(80, 0, 0), 600, 9),
	}
	var r := EngineAudio.nearest_running(vs, Vector3.ZERO, -1, 200.0)
	assert_eq(r["pos"], Vector3(10, 0, 0), "nearest running vehicle wins")

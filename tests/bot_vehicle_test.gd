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

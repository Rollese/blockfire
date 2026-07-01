extends TestCase
## SeatPose.occupants — pure parse of replicated VehicleState.seats into a
## {occupant_id -> {heading, seat}} map the renderer uses to pose riders seated.

func _veh(seats: Array, heading: float = 0.0) -> VehicleState:
	var v := VehicleState.new()
	v.seats = seats
	v.heading = heading
	return v

func test_no_vehicles_returns_empty() -> void:
	assert_eq(SeatPose.occupants({}).size(), 0, "no vehicles -> no occupants")

func test_empty_seats_returns_empty() -> void:
	# seat value 0 = empty slot (never a valid pawn id).
	var got := SeatPose.occupants({1000: _veh([0, 0, 0, 0])})
	assert_eq(got.size(), 0, "all-empty seats -> no occupants")

func test_maps_occupant_id_to_heading_and_seat() -> void:
	var got := SeatPose.occupants({1000: _veh([0, 42, 0, 7], 1.5)})
	assert_eq(got.size(), 2, "two filled seats")
	assert_true(got.has(42), "occupant 42 present")
	assert_eq(int(got[42]["seat"]), 1, "42 is in seat index 1")
	assert_eq(float(got[42]["heading"]), 1.5, "carries its vehicle heading")
	assert_eq(int(got[7]["seat"]), 3, "7 is in seat index 3")

func test_multiple_vehicles_merge() -> void:
	var got := SeatPose.occupants({
		1000: _veh([11, 0], 0.0),
		1001: _veh([0, 22], 2.0),
	})
	assert_eq(got.size(), 2, "one occupant from each vehicle")
	assert_eq(float(got[11]["heading"]), 0.0, "11 from vehicle 1000")
	assert_eq(float(got[22]["heading"]), 2.0, "22 from vehicle 1001")

func test_null_vehicle_skipped() -> void:
	var got := SeatPose.occupants({1000: null, 1001: _veh([5, 0])})
	assert_eq(got.size(), 1, "null VehicleState skipped, other still parsed")
	assert_true(got.has(5), "occupant 5 present")

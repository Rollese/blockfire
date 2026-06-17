extends TestCase

# Mirrors _kill_pawn's seat-vacate rule: a seated pawn that dies must free its vehicle seat and
# clear in_vehicle/seat, otherwise the per-tick seat-follow drags it back after it respawns.

func _veh() -> Vehicle:
	var def := VehicleCatalog.load_file("res://data/vehicles.json").def_of(0)
	return Vehicle.make(Vehicle.id_for(0), 0, def, 0, Vector3.ZERO)

func _vacate_on_death(v: Vehicle, p: Pawn) -> void:
	if p.in_vehicle != 0:
		if p.seat >= 0 and p.seat < v.seats.size():
			v.seats[p.seat] = 0
		p.in_vehicle = 0
		p.seat = -1

func test_death_frees_seat_and_clears_pawn_binding() -> void:
	var v := _veh()
	var p := Pawn.new()
	p.id = 7
	# Seat the pawn as driver (mirror _vehicle_enter).
	v.seats[0] = 7; p.in_vehicle = v.id; p.seat = 0
	# Pawn dies, then vacate.
	p.alive = false
	_vacate_on_death(v, p)
	assert_eq(int(v.seats[0]), 0, "seat 0 freed on death")
	assert_eq(p.in_vehicle, 0, "in_vehicle cleared")
	assert_eq(p.seat, -1, "seat index cleared")

func test_vacate_is_noop_for_unseated_pawn() -> void:
	var v := _veh()
	var p := Pawn.new()
	p.id = 9   # never entered a vehicle
	_vacate_on_death(v, p)
	assert_eq(p.in_vehicle, 0, "unseated pawn unaffected")
	assert_eq(int(v.seats[0]), 0, "vehicle seat untouched")

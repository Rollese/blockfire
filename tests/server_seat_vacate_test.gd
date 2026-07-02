extends TestCase
## Seat-vacate-on-death through the REAL server._vacate_seat (was a local mirror — batch 5.2).
## A seated pawn that dies must free its vehicle seat and clear in_vehicle/seat, otherwise the
## per-tick seat-follow drags it back after it respawns.

const F := preload("res://tests/server_fixture.gd")


func _srv_with_seated_pawn() -> Array:   # [srv, vehicle, pawn]
	var srv = autofree(F.make_server())
	var def := VehicleCatalog.load_file("res://data/vehicles.json").def_of(0)
	var v := Vehicle.make(Vehicle.id_for(0), 0, def, 0, Vector3.ZERO)
	srv._sim.world.spawn_vehicle(v)
	var p := F.add_pawn(srv, 7)
	v.seats[0] = 7
	p.in_vehicle = v.id
	p.seat = 0
	return [srv, v, p]


func test_death_frees_seat_and_clears_pawn_binding() -> void:
	var a := _srv_with_seated_pawn()
	var srv = a[0]; var v: Vehicle = a[1]; var p: Pawn = a[2]
	p.alive = false
	srv._vacate_seat(p)
	assert_eq(int(v.seats[0]), 0, "seat 0 freed on death")
	assert_eq(p.in_vehicle, 0, "in_vehicle cleared")
	assert_eq(p.seat, -1, "seat index cleared")


func test_vacate_is_noop_for_unseated_pawn() -> void:
	var a := _srv_with_seated_pawn()
	var srv = a[0]; var v: Vehicle = a[1]
	var q := F.add_pawn(srv, 9)   # never entered a vehicle
	srv._vacate_seat(q)
	assert_eq(q.in_vehicle, 0, "unseated pawn unaffected")
	assert_eq(int(v.seats[0]), 7, "someone else's seat untouched")


func test_kill_pawn_vacates_through_the_full_path() -> void:
	# End-to-end: _kill_pawn itself must vacate (the batch-1 bug was death paths skipping it).
	var a := _srv_with_seated_pawn()
	var srv = a[0]; var v: Vehicle = a[1]; var p: Pawn = a[2]
	srv._kill_pawn(7, p, 0, Weapon.AR, false, Revive.Source.BLAST)
	assert_false(p.alive)
	assert_eq(int(v.seats[0]), 0, "death through _kill_pawn frees the seat")
	assert_eq(p.seat, -1)

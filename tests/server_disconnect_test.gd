extends TestCase
## Disconnect-while-seated regression: _on_peer_disconnected must vacate the vehicle seat
## (as _kill_pawn already does). Before the fix the ghost occupant id stayed in v.seats
## forever — a disconnected driver made the vehicle permanently undrivable, corrupted
## free_seats on the deploy screen, and kept accruing transport distance.
## ServerMain built WITHOUT _ready() (no ENet), per the gate-test pattern.

func _seated_server() -> Dictionary:
	var srv = preload("res://server/server_main.gd").new()
	var p: Pawn = srv._sim.world.spawn(7)
	p.team = 0
	srv._clients[7] = {"team": 0, "deaths": 0, "kills": 0, "score": 0}
	srv._team_counts[0] += 1
	var def: Dictionary = VehicleCatalog.load_file("res://data/vehicles.json").def_of(0)
	var v: Vehicle = Vehicle.make(Vehicle.id_for(0), 0, def, 1, Vector3.ZERO)
	srv._sim.world.vehicles[v.id] = v
	v.seats[0] = 7
	p.in_vehicle = v.id
	p.seat = 0
	srv._transport_origin[7] = Vector3.ZERO
	srv._peer_to_id[null] = 7
	return {"srv": srv, "veh": v}

func test_disconnect_vacates_vehicle_seat() -> void:
	var s := _seated_server()
	var srv = s["srv"]; var v: Vehicle = s["veh"]
	srv._on_peer_disconnected(null)
	assert_eq(int(v.seats[0]), 0, "driver seat vacated on disconnect")
	assert_false(srv._transport_origin.has(7), "transport-origin entry cleaned up")
	srv.free()

func test_disconnect_of_unseated_player_is_harmless() -> void:
	var s := _seated_server()
	var srv = s["srv"]; var v: Vehicle = s["veh"]
	# Exit the vehicle first, then disconnect: no seat to vacate, must not crash.
	var p: Pawn = srv._sim.world.get_pawn(7)
	v.seats[0] = 0; p.in_vehicle = 0; p.seat = -1
	srv._on_peer_disconnected(null)
	assert_false(srv._clients.has(7), "client record removed")
	srv.free()

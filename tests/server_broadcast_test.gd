extends TestCase
## Human-fanout perf regression: every cosmetic broadcast used to iterate all 128 clients to
## skip bots, and _send_fob_lists sent a reliable FOB_LIST to every human EVERY tick (its three
## list siblings are changed+heartbeat). Now a cached _human_ids list drives _broadcast_humans,
## and FOB lists follow the changed+heartbeat pattern.

class SpyNet extends NetHost:
	var sends: Array = []
	func send_to(_peer: ENetPacketPeer, channel: int, bytes: PackedByteArray, flags: int) -> void:
		sends.append({"channel": channel, "size": bytes.size(), "flags": flags})

func _srv() -> Node:
	var srv = preload("res://server/server_main.gd").new()
	srv._net = SpyNet.new()
	srv._clients[1] = {"team": 0, "auto_deploy": false, "peer": null}
	srv._clients[2] = {"team": 1, "auto_deploy": false, "peer": null}
	srv._clients[3] = {"team": 0, "auto_deploy": true, "peer": null}
	srv._human_ids = [1, 2]
	return srv

func test_broadcast_humans_sends_to_humans_only_and_honors_exclude() -> void:
	var srv := _srv()
	srv._broadcast_humans(NetHost.CHANNEL_SNAPSHOT, PackedByteArray([1, 2, 3]))
	assert_eq((srv._net as SpyNet).sends.size(), 2, "one send per human, bots never scanned")
	(srv._net as SpyNet).sends.clear()
	srv._broadcast_humans(NetHost.CHANNEL_SNAPSHOT, PackedByteArray([1]), 0, 1)
	assert_eq((srv._net as SpyNet).sends.size(), 1, "exclude id skipped")
	srv.free()

func test_fob_lists_send_on_change_then_heartbeat_not_every_tick() -> void:
	var srv := _srv()
	srv._fobs["0:2"] = {"squad": 2, "team": 0, "id": 4200, "cell": Vector3i.ZERO, "built": false}
	var spy: SpyNet = srv._net
	srv._send_fob_lists()
	assert_eq(spy.sends.size(), 2, "initial state change -> both humans get their team list")
	spy.sends.clear()
	srv._send_fob_lists()
	srv._send_fob_lists()
	assert_eq(spy.sends.size(), 0, "unchanged state -> NO per-tick reliable resend")
	srv._sim.tick += 31   # past the heartbeat interval, list non-empty
	srv._send_fob_lists()
	assert_eq(spy.sends.size(), 2, "~1 Hz heartbeat covers late joiners")
	srv.free()

func test_disconnect_removes_human_id() -> void:
	var srv := _srv()
	srv._peer_to_id[null] = 1
	srv._sim.world.spawn(1)
	srv._clients[1]["deaths"] = 0
	srv._team_counts[0] += 2   # ids 1 (human) + 3 (bot) on team 0
	srv._on_peer_disconnected(null)
	assert_false(srv._human_ids.has(1), "disconnected human dropped from the fanout list")
	assert_true(srv._human_ids.has(2), "other humans unaffected")
	srv.free()

func test_mounted_gunner_exists_gates_lag_recording() -> void:
	# LagComp.record built ~129 dicts/tick for all pawns, but the mounted gun is the ONLY
	# remaining rewind consumer (bullets are present-time projectiles) — record only while
	# a live mounted-gun vehicle actually has a gunner seated.
	var srv := _srv()
	assert_false(srv._mounted_gunner_exists(), "no vehicles -> no recording needed")
	var def: Dictionary = VehicleCatalog.load_file("res://data/vehicles.json").def_of(0)
	var v: Vehicle = Vehicle.make(Vehicle.id_for(0), 0, def, 1, Vector3.ZERO)
	srv._sim.world.vehicles[v.id] = v
	assert_false(srv._mounted_gunner_exists(), "empty gunner seat -> no recording")
	for seat in v.seats.size():
		if int(v.seat_roles[seat]) == Vehicle.ROLE_GUNNER:
			v.seats[seat] = 7
			break
	assert_true(srv._mounted_gunner_exists(), "seated gunner on a live mounted-gun vehicle -> record")
	v.alive = false
	assert_false(srv._mounted_gunner_exists(), "destroyed vehicle -> no recording")
	srv.free()

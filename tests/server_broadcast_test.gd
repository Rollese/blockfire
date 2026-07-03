extends TestCase
## Human-fanout perf regression: every cosmetic broadcast used to iterate all 128 clients to
## skip bots, and _send_fob_lists sent a reliable FOB_LIST to every human EVERY tick (its three
## list siblings are changed+heartbeat). Now a cached _human_ids list drives _broadcast_humans,
## and FOB lists follow the changed+heartbeat pattern.

const F := preload("res://tests/server_fixture.gd")

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
	srv._build.fobs["0:2"] = {"squad": 2, "team": 0, "id": 4200, "cell": Vector3i.ZERO, "built": false}
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
	# LagComp.record builds ~129 dicts/tick for all pawns. Consumers are the mounted gun and
	# human-fired infantry bullets (fire.gd rewinds movers to the shooter's view tick); this test
	# pins the mounted-gun half of the gate — a live mounted-gun vehicle with a gunner seated.
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


# --- M7.5-P3: GADGET_LIST + GRENADE_FX audience widened to ALL clients (bots included) ---
# Fair-play rule: bots may consume exactly what a rendered human client receives. These two
# fan-outs carry mine/bag positions + thrown-grenade hints the support/avoidance AI needs.
# Fixture SpyNet records sends with peer=null for every client, so audience = send count.

func _srv_human_and_bot() -> Node:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1, 0, true)    # human (in _human_ids)
	F.add_client(srv, 2, 0, false)   # bot (auto_deploy=true, NOT in _human_ids)
	return srv

func test_gadget_list_fans_out_to_bots_too() -> void:
	var srv = _srv_human_and_bot()
	srv._bags.append({"owner": 1, "team": 0, "kind": 0, "pos": Vector3(3, 0, 4), "pool": 200})
	srv._broadcast_gadget_list()
	var pkts: Array = srv._net.bytes_of(Protocol.Msg.GADGET_LIST)
	assert_eq(pkts.size(), 2, "GADGET_LIST reaches human AND bot (was humans-only)")
	var s: Dictionary = srv._net.sends[0]
	assert_eq(int(s["channel"]), NetHost.CHANNEL_CONTROL, "channel unchanged: CONTROL")
	assert_eq(int(s["flags"]), ENetPacketPeer.FLAG_RELIABLE, "flags unchanged: reliable")

func test_gadget_list_keeps_changed_plus_heartbeat_cadence() -> void:
	var srv = _srv_human_and_bot()
	srv._bags.append({"owner": 1, "team": 0, "kind": 0, "pos": Vector3(3, 0, 4), "pool": 200})
	srv._broadcast_gadget_list()
	srv._net.sends.clear()
	srv._broadcast_gadget_list()
	srv._broadcast_gadget_list()
	assert_eq(srv._net.sends.size(), 0, "unchanged list -> no per-tick reliable resend")
	srv._sim.tick += 31   # past ReliableList.HEARTBEAT_TICKS, list non-empty
	srv._broadcast_gadget_list()
	assert_eq(srv._net.bytes_of(Protocol.Msg.GADGET_LIST).size(), 2, "heartbeat still fans to all")

func test_grenade_fx_reaches_bot_and_still_excludes_thrower() -> void:
	var srv = _srv_human_and_bot()
	srv._broadcast_grenade_fx(1, Vector3.ZERO, Vector3.FORWARD, 0)
	assert_eq(srv._net.bytes_of(Protocol.Msg.GRENADE_FX).size(), 1,
		"human thrower excluded -> the ONE send is the bot's (was 0 when humans-only)")
	assert_eq(int(srv._net.sends[0]["channel"]), NetHost.CHANNEL_SNAPSHOT, "channel unchanged: SNAPSHOT")
	assert_eq(int(srv._net.sends[0]["flags"]), 0, "flags unchanged: unreliable/droppable")
	srv._net.sends.clear()
	srv._broadcast_grenade_fx(2, Vector3.ZERO, Vector3.FORWARD, 0)
	assert_eq(srv._net.bytes_of(Protocol.Msg.GRENADE_FX).size(), 1,
		"bot thrower excluded -> only the human gets it")

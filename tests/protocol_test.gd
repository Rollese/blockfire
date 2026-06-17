extends TestCase

func test_kill_event_round_trip() -> void:
	var bytes := Protocol.encode_kill(7, 3, Weapon.DMR, true)
	assert_eq(Protocol.msg_type(bytes), Protocol.Msg.KILL)
	var d := Protocol.decode_kill(bytes)
	assert_eq(d["victim"], 7)
	assert_eq(d["killer"], 3)
	assert_eq(d["weapon"], Weapon.DMR)
	assert_eq(d["headshot"], true)

func test_shot_fx_round_trip() -> void:
	var b := Protocol.encode_shot_fx(Vector3(12.5, 1.8, -7.3), Vector3(0.0, 0.0, 1.0))
	assert_eq(Protocol.msg_type(b), Protocol.Msg.SHOT_FX)
	var d := Protocol.decode_shot_fx(b)
	assert_almost_eq(d["origin"].x, 12.5, 0.05, "origin x preserved to 0.1 m")
	assert_almost_eq(d["origin"].z, -7.3, 0.05, "origin z preserved to 0.1 m")
	assert_almost_eq(d["dir"].z, 1.0, 0.001, "aim dir preserved")

func test_hitmarker_round_trip() -> void:
	for hs in [false, true]:
		for lethal in [false, true]:
			var bytes := Protocol.encode_hitmarker(hs, lethal)
			assert_eq(Protocol.msg_type(bytes), Protocol.Msg.HITMARKER)
			var d := Protocol.decode_hitmarker(bytes)
			assert_eq(d["headshot"], hs, "headshot flag round-trips")
			assert_eq(d["lethal"], lethal, "lethal flag round-trips")

func test_give_up_message() -> void:
	assert_eq(Protocol.msg_type(Protocol.encode_give_up()), Protocol.Msg.GIVE_UP)


func test_match_state_round_trip() -> void:
	var points := [{"owner": -1, "attacker": 0, "cap": 0.5}, {"owner": 1, "attacker": -1, "cap": 1.0}]
	var bytes := Protocol.encode_match_state(points, [250, 7], false, -1, 42)
	assert_eq(Protocol.msg_type(bytes), Protocol.Msg.MATCH_STATE)
	var d := Protocol.decode_match_state(bytes)
	assert_eq(d["points"].size(), 2)
	assert_eq(d["points"][0]["owner"], -1)
	assert_eq(d["points"][0]["attacker"], 0)
	assert_almost_eq(d["points"][0]["cap"], 0.5, 0.01)
	assert_eq(d["points"][1]["owner"], 1)
	assert_eq(d["tickets"][0], 250)
	assert_eq(d["tickets"][1], 7)
	assert_eq(d["match_over"], false)
	assert_eq(d["winner"], -1)
	assert_eq(d["elapsed"], 42)


func test_build_request_round_trip() -> void:
	var b := Protocol.encode_build_request(1, Vector3i(-5, 0, 12), 3)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.BUILD_REQUEST)
	var d := Protocol.decode_build_request(b)
	assert_eq(d["type"], 1)
	assert_eq(d["cell"], Vector3i(-5, 0, 12))
	assert_eq(d["yaw"], 3)

func test_build_remove_round_trip() -> void:
	var b := Protocol.encode_build_remove(4242)
	assert_eq(Protocol.decode_build_remove(b)["id"], 4242)

func test_structure_delta_place_round_trip() -> void:
	var rec := {"id": 9, "type": 1, "cell": Vector3i(2, 0, -3), "yaw": 5, "health": 350, "owner": 7}
	var b := Protocol.encode_structure_delta(Protocol.OP_PLACE, rec)
	var d := Protocol.decode_structure_delta(b)
	assert_eq(d["op"], Protocol.OP_PLACE)
	assert_eq(d["rec"]["id"], 9)
	assert_eq(d["rec"]["cell"], Vector3i(2, 0, -3))
	assert_eq(d["rec"]["health"], 350)
	assert_eq(d["rec"]["owner"], 7)

func test_structure_delta_remove_round_trip() -> void:
	var b := Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": 9})
	var d := Protocol.decode_structure_delta(b)
	assert_eq(d["op"], Protocol.OP_REMOVE)
	assert_eq(d["id"], 9)

func test_structure_baseline_round_trip() -> void:
	var recs := [
		{"id": 1, "type": 0, "cell": Vector3i(0, 0, 0), "yaw": 0, "health": 150, "owner": 7},
		{"id": 2, "type": 1, "cell": Vector3i(1, 0, 0), "yaw": 2, "health": 350, "owner": 7},
	]
	var b := Protocol.encode_structure_baseline(Vector2i(3, -4), recs)
	var d := Protocol.decode_structure_baseline(b)
	assert_eq(d["region"], Vector2i(3, -4))
	assert_eq(d["records"].size(), 2)
	assert_eq(d["records"][1]["cell"], Vector3i(1, 0, 0))
	assert_eq(d["records"][1]["yaw"], 2)

func test_structure_delta_damage_roundtrip() -> void:
	var b := Protocol.encode_structure_delta(Protocol.OP_DAMAGE, {"id": 42, "bucket": 1})
	var d := Protocol.decode_structure_delta(b)
	assert_eq(d["op"], Protocol.OP_DAMAGE)
	assert_eq(d["id"], 42)
	assert_eq(d["bucket"], 1)

func test_structure_delta_place_and_remove_still_roundtrip() -> void:
	var rec := {"id": 7, "type": 1, "cell": Vector3i(-3, 0, 5), "yaw": 2, "health": 350, "owner": 9}
	var pd := Protocol.decode_structure_delta(Protocol.encode_structure_delta(Protocol.OP_PLACE, rec))
	assert_eq(pd["rec"]["id"], 7)
	assert_eq(pd["rec"]["health"], 350)
	var rd := Protocol.decode_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": 7}))
	assert_eq(rd["op"], Protocol.OP_REMOVE)
	assert_eq(rd["id"], 7)

func test_grenade_throw_roundtrip() -> void:
	var d := Protocol.decode_grenade_throw(Protocol.encode_grenade_throw(Vector3(1, 0, 0), Grenade.SMOKE))
	assert_almost_eq(d["dir"].x, 1.0, 0.001)
	assert_almost_eq(d["dir"].y, 0.0, 0.001)
	assert_eq(d["type"], Grenade.SMOKE)

func test_smoke_deployed_roundtrip() -> void:
	var d := Protocol.decode_smoke_deployed(Protocol.encode_smoke_deployed(Vector3(10, 0, -20), 6.0, 1234))
	assert_eq(d["pos"], Vector3(10, 0, -20))
	assert_eq(d["radius"], 6)
	assert_eq(d["expire_tick"], 1234)

func test_revive_action_roundtrip() -> void:
	var bytes := Protocol.encode_revive_action(4242, true)
	assert_eq(Protocol.msg_type(bytes), Protocol.Msg.REVIVE_ACTION)
	var d := Protocol.decode_revive_action(bytes)
	assert_eq(d["target"], 4242)
	assert_true(d["active"])

func test_revive_action_inactive_roundtrip() -> void:
	var d := Protocol.decode_revive_action(Protocol.encode_revive_action(1, false))
	assert_false(d["active"])

func test_self_bandage_type() -> void:
	assert_eq(Protocol.msg_type(Protocol.encode_self_bandage()), Protocol.Msg.SELF_BANDAGE)

func test_gadget_action_type() -> void:
	var b := Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE, Vector3.ZERO, Vector3(0, 0, 1), 0)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.GADGET_ACTION)

func test_gadget_action_roundtrip_dir() -> void:
	var d := Protocol.decode_gadget_action(Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE, Vector3.ZERO, Vector3(0, 0, 1), 0))
	assert_eq(d["action"], Protocol.GA_RPG_FIRE)
	assert_true(d["dir"].normalized().dot(Vector3(0, 0, 1)) > 0.999)

func test_gadget_action_roundtrip_pos() -> void:
	var d := Protocol.decode_gadget_action(Protocol.encode_gadget_action(Protocol.GA_C4_PLACE, Vector3(12.5, 0.0, -8.25), Vector3.ZERO, 0))
	# 0.1 m quantization (×10): worst-case error 0.05 m; -8.25 sits on a half-grid point so allow a hair over.
	assert_almost_eq(d["pos"].x, 12.5, 0.06)
	assert_almost_eq(d["pos"].z, -8.25, 0.06)

func test_gadget_action_roundtrip_target() -> void:
	var d := Protocol.decode_gadget_action(Protocol.encode_gadget_action(Protocol.GA_GIVE_START, Vector3.ZERO, Vector3(0, 0, 1), 777))
	assert_eq(d["target"], 777)

func test_welcome_carries_class() -> void:
	var d := Protocol.decode_welcome(Protocol.encode_welcome(5, 30, Loadout.ENGINEER))
	assert_eq(d["id"], 5)
	assert_eq(d["class"], Loadout.ENGINEER)

func test_deploy_request_roundtrip() -> void:
	var b := Protocol.encode_deploy_request(3)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.DEPLOY_REQUEST)
	assert_eq(Protocol.decode_deploy_request(b)["spawn_ref"], 3)

func test_deploy_request_carries_large_refs() -> void:
	# squadmate refs (200+pawn_id) and vehicle refs (400+slot) exceed a u8 — must survive the wire.
	for ref in [DeploySpawn.SQUADMATE_BASE + 128, DeploySpawn.VEHICLE_BASE + 3]:
		var b := Protocol.encode_deploy_request(ref)
		assert_eq(Protocol.decode_deploy_request(b)["spawn_ref"], ref, "ref %d round-trips" % ref)

func test_damage_event_roundtrip() -> void:
	var b := Protocol.encode_damage_event(1.2, 25)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.DAMAGE_EVENT)
	var d := Protocol.decode_damage_event(b)
	assert_almost_eq(d["bearing"], 1.2, 0.01, "world bearing preserved")
	assert_eq(d["amount"], 25)

func test_self_state_roundtrip() -> void:
	var b := Protocol.encode_self_state(17, true, 40, Weapon.AR)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.SELF_STATE)
	var d := Protocol.decode_self_state(b)
	assert_eq(d["mag"], 17)
	assert_true(d["reloading"])
	assert_eq(d["reload_remaining"], 40)
	assert_eq(d["weapon"], Weapon.AR)

func test_hello_carries_auto_deploy_default_true() -> void:
	var b := Protocol.encode_hello("Bot")
	var r := Protocol.body_reader(b)
	assert_eq(r.get_u16(), Protocol.VERSION)
	assert_eq(r.get_utf8_string(), "Bot")
	assert_eq(r.get_u8(), 1, "auto_deploy defaults to 1 (true)")

func test_hello_auto_deploy_false_for_rendered_client() -> void:
	var b := Protocol.encode_hello("Player", false)
	var r := Protocol.body_reader(b)
	r.get_u16(); r.get_utf8_string()
	assert_eq(r.get_u8(), 0, "rendered client requests manual deploy")

func test_roster_roundtrip() -> void:
	var rows := [
		{"id": 7, "name": "Ada", "team": 0, "squad": 1, "kills": 3, "deaths": 1, "score": 300},
		{"id": 9, "name": "Bo", "team": 1, "squad": 0, "kills": 0, "deaths": 2, "score": 0},
	]
	var b := Protocol.encode_roster(rows)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.ROSTER)
	var d := Protocol.decode_roster(b)
	var out: Array = d["rows"]
	assert_eq(out.size(), 2)
	assert_eq(out[0]["name"], "Ada")
	assert_eq(out[0]["kills"], 3)
	assert_eq(out[1]["id"], 9)
	assert_eq(out[1]["deaths"], 2)

func test_set_squad_roundtrip() -> void:
	var b := Protocol.encode_set_squad(4)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.SET_SQUAD)
	assert_eq(Protocol.decode_set_squad(b)["squad"], 4)

func test_death_info_roundtrip() -> void:
	var atk := [{"id": 7, "dmg": 80}, {"id": 9, "dmg": 20}]
	var b := Protocol.encode_death_info(7, Weapon.AR, 42.5, 35, atk)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.DEATH_INFO)
	var d := Protocol.decode_death_info(b)
	assert_eq(d["killer"], 7)
	assert_eq(d["weapon"], Weapon.AR)
	assert_almost_eq(d["distance"], 42.5, 0.1, "distance preserved to 0.1m")
	assert_eq(d["killer_hp"], 35)
	assert_eq(d["attackers"].size(), 2)
	assert_eq(d["attackers"][0]["id"], 7)
	assert_eq(d["attackers"][0]["dmg"], 80)

func test_self_state_carries_throwables() -> void:
	var thr := [{"kind": 0, "count": 1}, {"kind": 1, "count": 2}]   # frag ready, 2 gadget charges
	var b := Protocol.encode_self_state(17, false, 0, Weapon.AR, thr)
	var d := Protocol.decode_self_state(b)
	assert_eq(d["mag"], 17)
	assert_eq(d["throwables"].size(), 2)
	assert_eq(d["throwables"][1]["kind"], 1)
	assert_eq(d["throwables"][1]["count"], 2)

func test_self_state_without_throwables_defaults_empty() -> void:
	var b := Protocol.encode_self_state(30, false, 0, Weapon.AR)   # 4-arg (pre-C3 senders)
	var d := Protocol.decode_self_state(b)
	assert_eq(d["throwables"], [], "absent block decodes as empty list")
	assert_eq(d["being_revived"], false, "being_revived defaults false")

func test_self_state_carries_being_revived() -> void:
	var thr := [{"kind": 0, "count": 1}]
	var b := Protocol.encode_self_state(20, false, 0, Weapon.AR, thr, true)
	var d := Protocol.decode_self_state(b)
	assert_eq(d["being_revived"], true, "being_revived round-trips")
	assert_eq(d["throwables"].size(), 1, "throwables still decode after being_revived byte")

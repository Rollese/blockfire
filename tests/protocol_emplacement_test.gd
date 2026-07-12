extends TestCase

func test_version_bumped() -> void:
	assert_eq(Protocol.VERSION, 11)

func test_emplacement_action_roundtrip() -> void:
	var b := Protocol.encode_emplacement_action(Protocol.EA_MOUNT, Emplacement.id_for(3))
	var d := Protocol.decode_emplacement_action(b)
	assert_eq(int(d["action"]), Protocol.EA_MOUNT)
	assert_eq(int(d["nest_id"]), Emplacement.id_for(3))

func test_deploy_action_reuses_gadget_action() -> void:
	var b := Protocol.encode_gadget_action(Protocol.GA_LMG_DEPLOY, Vector3(5, 0, 6), Vector3(0, 0, 1), 0)
	var d := Protocol.decode_gadget_action(b)
	assert_eq(int(d["action"]), Protocol.GA_LMG_DEPLOY)
	assert_almost_eq((d["pos"] as Vector3).x, 5.0, 0.05)

func test_emplacement_list_roundtrip() -> void:
	var list := [{"id": Emplacement.id_for(1), "pos": Vector3(3, 0, 4), "facing_yaw": 0.5,
		"turret_yaw": 0.7, "hp_frac": 0.5, "occupant": 9, "team": 1}]
	var enc := Protocol.encode_emplacement_list(list)
	var out := Protocol.decode_emplacement_list(enc)
	assert_eq(out.size(), 1)
	assert_eq(int(out[0]["id"]), Emplacement.id_for(1))
	assert_almost_eq(float(out[0]["turret_yaw"]), 0.7, 0.001)
	assert_almost_eq(float(out[0]["hp_frac"]), 0.5, 0.01)
	assert_eq(int(out[0]["occupant"]), 9)

func test_self_state_carries_mount_fields() -> void:
	var b := Protocol.encode_self_state(30, false, 0, 0, [], false, 0.0, 0, 0, false, 0.0, 0.0,
		100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 0, 0, 0,
		Emplacement.id_for(2), 42, 88, true)   # ...mounted_nest, mg_heat, mg_ammo, mg_overheated
	var d := Protocol.decode_self_state(b)
	assert_eq(int(d["mounted_nest"]), Emplacement.id_for(2))
	assert_eq(int(d["mg_heat"]), 42)
	assert_eq(int(d["mg_ammo"]), 88)
	assert_true(bool(d["mg_overheated"]))

func test_self_state_mount_tail_absent_defaults() -> void:
	# an OLD sender (no mount tail) must decode to safe defaults, not garbage
	var full := Protocol.encode_self_state(30, false, 0, 0, [], false, 0.0, 0, 0, false, 0.0, 0.0,
		100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 0, 0, 0,
		Emplacement.id_for(2), 42, 88, true)
	var old := full.slice(0, full.size() - 8)   # strip the 8-byte mount tail
	var d := Protocol.decode_self_state(old)
	assert_eq(int(d["mounted_nest"]), 0)
	assert_eq(int(d["mg_heat"]), 0)
	assert_eq(int(d["mg_ammo"]), 0)
	assert_false(bool(d["mg_overheated"]))

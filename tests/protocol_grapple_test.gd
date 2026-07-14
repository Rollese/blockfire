extends TestCase
## M19 grapple wire: VERSION==12; DEPLOYED_LADDER_LIST + CUT_LADDER round-trip; SELF_STATE
## trailing grapple_charges byte (present + absent-defaults-to-zero).

func test_version_is_13() -> void:
	assert_eq(Protocol.VERSION, 13, "VERSION bumped for the grapple wire")

func test_deployed_ladder_list_round_trips() -> void:
	var list := [
		{"id": 7, "x": 12.5, "z": -3.0, "bottom_y": 0.0, "top_y": 6.5, "cuttable": true},
		{"id": 9, "x": -40.0, "z": 88.2, "bottom_y": 1.0, "top_y": 5.0, "cuttable": false},
	]
	var bytes := Protocol.encode_deployed_ladder_list(list)
	var out := Protocol.decode_deployed_ladder_list(bytes)
	assert_eq(out.size(), 2, "two ladders decode")
	assert_eq(int(out[0]["id"]), 7)
	assert_true(abs(float(out[0]["x"]) - 12.5) < 0.1, "x within 0.1 m quantization")
	assert_true(abs(float(out[0]["top_y"]) - 6.5) < 0.1, "top_y within 0.1 m")
	assert_true(bool(out[0]["cuttable"]), "cuttable flag true")
	assert_false(bool(out[1]["cuttable"]), "cuttable flag false")

func test_cut_ladder_round_trips() -> void:
	var bytes := Protocol.encode_cut_ladder(4242)
	var d := Protocol.decode_cut_ladder(bytes)
	assert_eq(int(d["ladder_id"]), 4242, "ladder id survives the wire")

func test_self_state_carries_grapple_charges() -> void:
	var b := Protocol.encode_self_state(30, false, 0, 0, [], false, 0.0, 0, 0, false, 0.0, 0.0,
		100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 0, 0, 0,
		0, 0, 0, false, 0, 1)   # ...shield_hp_frac=0, grapple_charges=1
	var d := Protocol.decode_self_state(b)
	assert_eq(int(d["grapple_charges"]), 1)

func test_self_state_grapple_absent_defaults_zero() -> void:
	var full := Protocol.encode_self_state(30, false, 0, 0, [], false, 0.0, 0, 0, false, 0.0, 0.0,
		100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 0, 0, 0,
		0, 0, 0, false, 0, 1)
	var old := full.slice(0, full.size() - 2)   # strip the M2 spare_mags-count byte + the 1-byte grapple tail
	var d := Protocol.decode_self_state(old)
	assert_eq(int(d["grapple_charges"]), 0, "old/short packet -> 0, no misalignment")

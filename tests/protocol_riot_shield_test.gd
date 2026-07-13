extends TestCase
## M19 P5: wire — BTN_SHIELD round-trips; SELF_STATE carries shield-HP fraction; VERSION==11.

func test_version_is_12() -> void:
	assert_eq(Protocol.VERSION, 12, "VERSION bumped for the shield wire")

func test_btn_shield_round_trips() -> void:
	var buttons := InputCommand.BTN_SHIELD | InputCommand.BTN_AIM
	var bytes := InputCommand.encode(1, 0, 0.0, 0.0, 0.0, 0.0, buttons, 0)
	var f: Dictionary = InputCommand.decode(bytes)["frames"][0]
	assert_true((int(f["buttons"]) & InputCommand.BTN_SHIELD) != 0, "BTN_SHIELD survives the wire")
	assert_eq(InputCommand.BTN_SHIELD, 1024, "shield is bit 10 (free above BTN_SHOVEL)")

func test_self_state_carries_shield_frac() -> void:
	var b := Protocol.encode_self_state(30, false, 0, 0, [], false, 0.0, 0, 0, false, 0.0, 0.0,
		100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 0, 0, 0,
		0, 0, 0, false, 255)   # ...mounted_nest, mg_heat, mg_ammo, mg_overheated, shield_hp_frac
	var d := Protocol.decode_self_state(b)
	assert_eq(int(d["shield_hp_frac"]), 255)

func test_self_state_shield_frac_absent_defaults_to_zero() -> void:
	# An OLD sender (pre-P5, no shield tail byte) must decode to a safe default, not garbage.
	var full := Protocol.encode_self_state(30, false, 0, 0, [], false, 0.0, 0, 0, false, 0.0, 0.0,
		100.0, 0.0, true, false, 0, 0.0, false, 0, false, 0, 0, 0, 0,
		0, 0, 0, false, 255)
	var old := full.slice(0, full.size() - 2)   # strip the M19 grapple byte + the 1-byte shield tail
	var d := Protocol.decode_self_state(old)
	assert_eq(int(d["shield_hp_frac"]), 0)

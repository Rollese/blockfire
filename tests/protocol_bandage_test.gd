extends TestCase
## M16 wire: BANDAGE_ACTION + BLEEDING_LIST roundtrips, and SELF_STATE's appended bleed fields
## (append-only growth — an old/short packet decodes to safe defaults).

func test_bandage_action_roundtrip() -> void:
	var b := Protocol.encode_bandage_action(4242, true)
	assert_eq(b[0], Protocol.Msg.BANDAGE_ACTION)
	var d := Protocol.decode_bandage_action(b)
	assert_eq(int(d["target"]), 4242)
	assert_true(bool(d["active"]))

func test_bandage_action_inactive() -> void:
	var d := Protocol.decode_bandage_action(Protocol.encode_bandage_action(7, false))
	assert_eq(int(d["target"]), 7)
	assert_false(bool(d["active"]))

func test_bleeding_list_roundtrip() -> void:
	var b := Protocol.encode_bleeding_list([11, 22, 33])
	assert_eq(b[0], Protocol.Msg.BLEEDING_LIST)
	var ids := Protocol.decode_bleeding_list(b)
	assert_eq(ids.size(), 3)
	assert_eq(int(ids[0]), 11)
	assert_eq(int(ids[2]), 33)

func test_bleeding_list_empty() -> void:
	assert_eq(Protocol.decode_bleeding_list(Protocol.encode_bleeding_list([])).size(), 0)

func test_self_state_carries_bleed_fields() -> void:
	var b := Protocol.encode_self_state(10, false, 0, Weapon.AR, [], false, 0.0, 0, 3, false,
		0.0, 0.0, 100.0, 0.0, true, false, 0, 0.0, false, 0, true, 128)
	var d := Protocol.decode_self_state(b)
	assert_true(bool(d["bleeding"]))
	assert_eq(int(d["bandage_progress"]), 128)

func test_self_state_old_packet_defaults_bleed_fields() -> void:
	# A packet without the appended M16 bytes decodes to not-bleeding / zero progress.
	# Build a minimal legacy-length self_state (only the required head fields present).
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.SELF_STATE)
	buf.put_u8(10); buf.put_u8(0); buf.put_u16(0); buf.put_u8(Weapon.AR)
	var d := Protocol.decode_self_state(buf.data_array)
	assert_false(bool(d["bleeding"]))
	assert_eq(int(d["bandage_progress"]), 0)

func test_self_state_carries_stim_fields() -> void:
	# M19 P2b-medic: stim charges/ticks are appended last (owner-only), after reserve.
	var b := Protocol.encode_self_state(10, false, 0, Weapon.AR, [], false, 0.0, 0, 3, false,
		0.0, 0.0, 100.0, 0.0, true, false, 0, 0.0, false, 0, true, 128, 0, 2, 144)
	var d := Protocol.decode_self_state(b)
	assert_eq(int(d["stim_charges"]), 2)
	assert_eq(int(d["stim_ticks"]), 144)

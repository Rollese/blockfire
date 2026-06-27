extends TestCase
## INPUT packets carry a bundle of the last N input frames (redundancy against packet loss).
## decode() returns {ack_seq, frames:[...]} with frames ordered oldest -> newest.

func test_aim_bit_survives_u16_buttons() -> void:
	# BTN_AIM is bit 9 (256) — only survives because buttons is a u16 on the wire now.
	var buttons := InputCommand.BTN_AIM | InputCommand.BTN_FIRE
	var bytes := InputCommand.encode(1, 0, 0.0, 0.0, 0.0, 0.0, buttons, 0)
	var f: Dictionary = InputCommand.decode(bytes)["frames"][0]
	assert_true(int(f["buttons"]) & InputCommand.BTN_AIM, "aim bit round-trips")
	assert_true(int(f["buttons"]) & InputCommand.BTN_FIRE, "fire bit still round-trips")

func test_single_frame_round_trip() -> void:
	var buttons := InputCommand.BTN_FIRE | InputCommand.BTN_SPRINT
	var bytes := InputCommand.encode(123, 45, 1.0, -0.5, 1.2, -0.3, buttons, 77)
	assert_eq(Protocol.msg_type(bytes), Protocol.Msg.INPUT)
	var d := InputCommand.decode(bytes)
	assert_eq(d["ack_seq"], 45)
	assert_eq(d["frames"].size(), 1)
	var f: Dictionary = d["frames"][0]
	assert_eq(f["client_tick"], 123)
	assert_eq(f["view_server_tick"], 77)
	assert_almost_eq(f["move_x"], 1.0, 0.001)
	assert_almost_eq(f["move_y"], -0.5, 0.001)
	assert_almost_eq(f["yaw"], 1.2, 0.001)
	assert_eq(f["buttons"], buttons)

func test_view_tick_defaults_to_zero() -> void:
	var d := InputCommand.decode(InputCommand.encode(0, 0, 0.0, 0.0, 0.0, 0.0, 0))
	assert_eq(d["frames"][0]["view_server_tick"], 0)

func test_move_is_clamped_to_unit() -> void:
	var d := InputCommand.decode(InputCommand.encode(0, 0, 5.0, 0.0, 0.0, 0.0, 0))
	assert_almost_eq(d["frames"][0]["move_x"], 1.0, 0.001)

func test_bundle_round_trip_preserves_order_and_fields() -> void:
	var frames := [
		{"client_tick": 100, "move_x": 0.0, "move_y": 1.0, "yaw": 0.1, "pitch": 0.0, "buttons": 0, "view_server_tick": 10},
		{"client_tick": 101, "move_x": -1.0, "move_y": 0.0, "yaw": 0.2, "pitch": -0.1, "buttons": InputCommand.BTN_FIRE, "view_server_tick": 11},
		{"client_tick": 102, "move_x": 0.5, "move_y": -0.5, "yaw": 0.3, "pitch": 0.2, "buttons": InputCommand.BTN_RELOAD, "view_server_tick": 12},
	]
	var bytes := InputCommand.encode_bundle(99, frames)
	var d := InputCommand.decode(bytes)
	assert_eq(d["ack_seq"], 99)
	assert_eq(d["frames"].size(), 3)
	for i in 3:
		var got: Dictionary = d["frames"][i]
		var want: Dictionary = frames[i]
		assert_eq(got["client_tick"], want["client_tick"], "frame %d client_tick" % i)
		assert_eq(got["view_server_tick"], want["view_server_tick"], "frame %d view_tick" % i)
		assert_eq(got["buttons"], want["buttons"], "frame %d buttons" % i)
		assert_almost_eq(got["move_x"], float(want["move_x"]), 0.001, "frame %d move_x" % i)
		assert_almost_eq(got["move_y"], float(want["move_y"]), 0.001, "frame %d move_y" % i)
		assert_almost_eq(got["yaw"], float(want["yaw"]), 0.001, "frame %d yaw" % i)

func test_empty_bundle_decodes_to_no_frames() -> void:
	var d := InputCommand.decode(InputCommand.encode_bundle(7, []))
	assert_eq(d["ack_seq"], 7)
	assert_eq(d["frames"].size(), 0)

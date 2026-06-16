extends TestCase

func test_vehicle_action_enter_roundtrips() -> void:
	var b := Protocol.encode_vehicle_action(Protocol.VA_ENTER, Vehicle.id_for(2), 4)
	assert_eq(Protocol.msg_type(b), Protocol.Msg.VEHICLE_ACTION)
	var d := Protocol.decode_vehicle_action(b)
	assert_eq(int(d["action"]), Protocol.VA_ENTER)
	assert_eq(int(d["vehicle_id"]), Vehicle.id_for(2))
	assert_eq(int(d["seat_hint"]), 4)

func test_vehicle_action_exit_roundtrips() -> void:
	var b := Protocol.encode_vehicle_action(Protocol.VA_EXIT, 0, 0)
	var d := Protocol.decode_vehicle_action(b)
	assert_eq(int(d["action"]), Protocol.VA_EXIT)

func test_vehicle_destroyed_roundtrips() -> void:
	var b := Protocol.encode_vehicle_destroyed(Vehicle.id_for(1))
	assert_eq(Protocol.msg_type(b), Protocol.Msg.VEHICLE_DESTROYED)
	assert_eq(int(Protocol.decode_vehicle_destroyed(b)["vehicle_id"]), Vehicle.id_for(1))

func test_repair_subactions_distinct() -> void:
	assert_true(Protocol.GA_REPAIR_START != Protocol.GA_REPAIR_STOP)

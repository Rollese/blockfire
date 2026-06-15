extends TestCase

func test_kill_event_round_trip() -> void:
	var bytes := Protocol.encode_kill(7, 3, Weapon.DMR, true)
	assert_eq(Protocol.msg_type(bytes), Protocol.Msg.KILL)
	var d := Protocol.decode_kill(bytes)
	assert_eq(d["victim"], 7)
	assert_eq(d["killer"], 3)
	assert_eq(d["weapon"], Weapon.DMR)
	assert_eq(d["headshot"], true)


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

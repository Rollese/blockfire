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

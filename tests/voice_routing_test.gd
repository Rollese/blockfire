extends TestCase

func _entry(pos: Vector3, team: int, squad: int, peer: int, alive := true) -> Dictionary:
	return {"pos": pos, "team": team, "squad": squad, "voice_peer": peer, "alive": alive}

func _table() -> Dictionary:
	return {
		1: _entry(Vector3.ZERO, 0, 1, 101),            # speaker
		2: _entry(Vector3(10, 0, 0), 0, 1, 102),       # same squad, 10m
		3: _entry(Vector3(20, 0, 0), 1, 2, 103),       # enemy, 20m
		4: _entry(Vector3(70, 0, 0), 0, 1, 104),       # squadmate but out of prox range
		5: _entry(Vector3(5, 0, 0), 1, 2, 0),          # in range but NO voice peer
		6: _entry(Vector3(30, 0, 0), 1, 2, 106, false),# in range, enemy, but dead
	}

func test_proximity_includes_in_range_regardless_of_team() -> void:
	var r := VoiceRouting.recipients_for(1, _table(), VoicePacket.KIND_PROXIMITY, 50.0, 12)
	assert_true(r.has(2), "ally in range")
	assert_true(r.has(3), "ENEMY in range is heard (BattleBit)")
	assert_false(r.has(4), "out of range excluded")
	assert_false(r.has(5), "no voice peer excluded")
	assert_false(r.has(6), "dead excluded")
	assert_false(r.has(1), "self excluded")

func test_proximity_sorted_by_distance_and_capped() -> void:
	var r := VoiceRouting.recipients_for(1, _table(), VoicePacket.KIND_PROXIMITY, 50.0, 1)
	assert_eq(r.size(), 1, "fanout cap applied")
	assert_eq(r[0], 2, "nearest kept")

func test_squad_is_team_and_squad_private() -> void:
	var r := VoiceRouting.recipients_for(1, _table(), VoicePacket.KIND_SQUAD, 50.0, 12)
	assert_true(r.has(2), "same team+squad")
	assert_false(r.has(3), "enemy never on squad channel")
	assert_true(r.has(4), "squadmate out of range still hears squad")
	assert_false(r.has(5), "no voice peer excluded")

func test_equidistant_tie_break_is_deterministic_lowest_id() -> void:
	# Two candidates at the SAME distance; with fanout 1 the lower id must win deterministically.
	var t := {
		1: _entry(Vector3.ZERO, 0, 1, 101),       # speaker
		8: _entry(Vector3(10, 0, 0), 0, 1, 108),  # 10m
		3: _entry(Vector3(0, 0, 10), 0, 1, 103),  # also 10m (same distance)
	}
	var r := VoiceRouting.recipients_for(1, t, VoicePacket.KIND_PROXIMITY, 50.0, 1)
	assert_eq(r.size(), 1, "fanout cap applied")
	assert_eq(r[0], 3, "equidistant tie-break keeps lower id")

func test_unknown_speaker_returns_empty() -> void:
	assert_eq(VoiceRouting.recipients_for(99, _table(), VoicePacket.KIND_PROXIMITY, 50.0, 12), [])

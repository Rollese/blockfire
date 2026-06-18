extends TestCase
## Tests the pure table-builder the tick uses, in isolation from the live server node.

func test_build_route_table_from_world_rows() -> void:
	var rows := [
		{"id": 1, "pos": Vector3.ZERO, "team": 0, "squad": 1, "voice_peer": 101, "alive": true},
		{"id": 2, "pos": Vector3(3, 0, 0), "team": 1, "squad": 2, "voice_peer": 0, "alive": true},
	]
	var t := ServerVoice.build_route_table(rows)
	assert_eq(t[1]["team"], 0)
	assert_eq(t[1]["voice_peer"], 101)
	assert_eq(t[2]["voice_peer"], 0, "unconnected player carried with peer 0")
	assert_false(t.has(99))

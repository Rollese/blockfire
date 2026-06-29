# tests/protocol_fob_test.gd
extends TestCase

func test_place_fob_round_trip() -> void:
	var b := Protocol.encode_place_fob(Vector3i(12, 0, -7), 5)
	assert_eq(b[0], Protocol.Msg.PLACE_FOB, "tagged PLACE_FOB")
	var d := Protocol.decode_place_fob(b)
	assert_eq(d["cell"], Vector3i(12, 0, -7), "cell round-trips")
	assert_eq(int(d["yaw"]), 5, "yaw round-trips")

func test_remove_fob_round_trip() -> void:
	var b := Protocol.encode_remove_fob()
	assert_eq(b[0], Protocol.Msg.REMOVE_FOB, "tagged REMOVE_FOB")

func test_fob_list_round_trip() -> void:
	var list := [{"squad": 3, "structure_id": 4101, "under_construction": 1, "enabled": 0},
		{"squad": 5, "structure_id": 4102, "under_construction": 0, "enabled": 1}]
	var b := Protocol.encode_fob_list(list)
	assert_eq(b[0], Protocol.Msg.FOB_LIST, "tagged FOB_LIST")
	var out := Protocol.decode_fob_list(b)
	assert_eq(out.size(), 2, "two entries")
	assert_eq(int(out[0]["squad"]), 3, "squad round-trips")
	assert_eq(int(out[0]["structure_id"]), 4101, "structure_id round-trips")
	assert_eq(int(out[0]["under_construction"]), 1, "uc bit round-trips")
	assert_eq(int(out[1]["enabled"]), 1, "enabled bit round-trips")

func _map() -> MapDef:
	var json := '{"points":[],"bases":[{"team":0,"pos":[-100,0,0],"radius":10},{"team":1,"pos":[100,0,0],"radius":10}]}'
	return MapDef.from_json_string(json)["map"]

func _conq(m: MapDef) -> ConquestState:
	return ConquestState.new(m)

func test_deploy_fob_ref_enumerated_and_resolves() -> void:
	var m := _map()
	var c := _conq(m)
	# fobs candidate array shape the server passes to DeploySpawn.
	var fobs := [{"squad": 2, "pos": Vector3(10, 0, 10), "enabled": true}]
	var refs := DeploySpawn.enumerate(0, m, c, [], [], fobs)
	var fref := DeploySpawn.FOB_BASE + 2
	assert_true(refs.has(fref), "the squad's enabled FOB is an offered ref")
	assert_true(DeploySpawn.is_valid(0, fref, m, c, [], [], fobs), "FOB ref validates")
	var pos := DeploySpawn.resolve(0, fref, m, c, [], [], fobs)
	assert_true(absf(pos.x - 10.0) <= DeploySpawn.JITTER + 0.001, "resolves near the FOB (within jitter)")

func test_deploy_fob_ref_rejected_when_disabled() -> void:
	var m := _map()
	var c := _conq(m)
	var fobs := [{"squad": 2, "pos": Vector3(10, 0, 10), "enabled": false}]
	var refs := DeploySpawn.enumerate(0, m, c, [], [], fobs)
	assert_false(refs.has(DeploySpawn.FOB_BASE + 2), "a disabled FOB is not offered")
	assert_false(DeploySpawn.is_valid(0, DeploySpawn.FOB_BASE + 2, m, c, [], [], fobs), "disabled FOB ref invalid")

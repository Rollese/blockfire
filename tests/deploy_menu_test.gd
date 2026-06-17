extends TestCase

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1},{"id":"B","pos":[200,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

func _map() -> MapDef:
	return MapDef.from_json_string(MAP_JSON)["map"]

func test_populate_lists_enumerated_refs_and_emits_on_press() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	c.points[0]["owner"] = 0   # team 0 owns point index 0 -> ref 1 valid
	var menu := DeployMenu.new()
	menu.populate(0, m, c)
	var expected := DeploySpawn.enumerate(0, m, c)   # [0, 1]
	assert_eq(menu.refs, expected, "menu offers exactly the enumerated refs")
	# capture the emitted ref
	var got := {"ref": -999}
	menu.deploy_requested.connect(func(r): got["ref"] = r)
	menu.emit_deploy(expected[1])   # see helper below
	assert_eq(got["ref"], expected[1], "pressing a spawn emits its ref")
	menu.free()

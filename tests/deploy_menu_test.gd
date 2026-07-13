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

func test_populate_offers_enabled_squad_fob() -> void:
	# M12-P3: a built+enabled FOB for squad 2 should appear as a spawn ref (FOB_BASE + 2); a disabled
	# (enemy-suppressed) FOB must NOT.
	var m := _map()
	var c := ConquestState.new(m)
	var menu := DeployMenu.new()
	var fobs := [{"squad": 2, "enabled": true}, {"squad": 5, "enabled": false}]
	menu.populate(0, m, c, [], [], fobs)
	assert_true(menu.refs.has(DeploySpawn.FOB_BASE + 2), "enabled squad-2 FOB offered as a spawn")
	assert_false(menu.refs.has(DeploySpawn.FOB_BASE + 5), "disabled squad-5 FOB not offered")
	menu.free()

func test_populate_keeps_open_loadout_editor_visible() -> void:
	# A4 round-2: a data-refresh repopulate (e.g. a FOB_LIST content change while the player lingers on
	# the deploy screen) must NOT yank an open loadout editor shut. Only close_loadout_editor() / the
	# Done button / a fresh death screen should close it.
	var m := _map()
	var c := ConquestState.new(m)
	var menu := DeployMenu.new()
	menu.populate(0, m, c)
	menu._on_loadout_btn_pressed()   # open the editor as the player would
	assert_true(menu._class_select.visible, "loadout editor is open before the refresh")
	menu.populate(0, m, c)           # data refresh (FOB churn) re-runs populate
	assert_true(menu._class_select.visible, "open loadout editor survives a populate/data-refresh")
	menu.free()

func test_close_loadout_editor_hides_it() -> void:
	# The explicit close path (called on the alive->dead transition) hides the editor.
	var m := _map()
	var c := ConquestState.new(m)
	var menu := DeployMenu.new()
	menu.populate(0, m, c)
	menu._on_loadout_btn_pressed()
	assert_true(menu._class_select.visible, "editor open")
	menu.close_loadout_editor()
	assert_false(menu._class_select.visible, "close_loadout_editor() hides the editor")
	# null-guard: no crash if the panel was never built.
	var bare := DeployMenu.new()
	bare.close_loadout_editor()
	bare.free()
	menu.free()

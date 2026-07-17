extends TestCase
## The plugin itself needs a live EditorInterface, which a headless test run does not have. So this
## verifies what CAN be verified without one: the manifest is well-formed and the scripts parse and
## expose the expected surface. Interactive behaviour is owner-gated (see M22's gate).

func test_plugin_cfg_is_well_formed() -> void:
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("res://addons/map_editor/plugin.cfg"), OK, "plugin.cfg loads")
	assert_eq(String(cfg.get_value("plugin", "script")), "map_editor_plugin.gd", "script entry point")
	assert_ne(String(cfg.get_value("plugin", "name")), "", "plugin has a name")

func test_plugin_script_parses_and_is_an_editor_plugin() -> void:
	var s: GDScript = load("res://addons/map_editor/map_editor_plugin.gd")
	assert_ne(s, null, "plugin script parses")
	assert_true(s.can_instantiate(), "plugin script is instantiable")
	assert_eq(String(s.get_instance_base_type()), "EditorPlugin", "extends EditorPlugin")

func test_dock_script_parses() -> void:
	var s: GDScript = load("res://addons/map_editor/ui/editor_dock.gd")
	assert_ne(s, null, "dock script parses")
	assert_true(s.can_instantiate(), "dock script is instantiable")

func test_tool_modes_are_declared() -> void:
	var s: GDScript = load("res://addons/map_editor/ui/editor_dock.gd")
	var consts := s.get_script_constant_map()
	assert_true(consts.has("Mode"), "dock declares a Mode enum")
	var m: Dictionary = consts["Mode"]
	for expected in ["TERRAIN", "BUILDING", "PROP", "MARKER", "ROAD"]:
		assert_true(m.has(expected), "Mode.%s exists" % expected)

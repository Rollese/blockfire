extends TestCase

func test_flag_defaults_true() -> void:
	var s := ClientSettings.new()
	assert_true(s.use_model_characters, "default ON: imported GLB soldier models (playtest 2026-06-18)")

func test_flag_round_trips_through_configfile() -> void:
	var path := "user://test_model_flag.cfg"
	var a := ClientSettings.new()
	a.use_model_characters = true
	a.save_to(path)
	var b := ClientSettings.new()
	b.load_from(path)
	assert_true(b.use_model_characters, "flag persists across save/load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

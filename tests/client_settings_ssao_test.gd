extends TestCase

func test_ssao_defaults_true() -> void:
	var s := ClientSettings.new()
	assert_true(s.ssao_enabled, "SSAO on by default (client.tscn ships ssao_enabled = true)")

func test_ssao_round_trips_through_configfile() -> void:
	var path := "user://ssao_test.cfg"
	var a := ClientSettings.new()
	a.ssao_enabled = false
	a.save_to(path)
	var b := ClientSettings.new()
	b.load_from(path)
	assert_false(b.ssao_enabled, "SSAO toggle persists across save/load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

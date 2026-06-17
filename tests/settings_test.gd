extends TestCase

func test_save_then_load_roundtrips() -> void:
	var path := "user://test_settings_%d.cfg" % (Time.get_ticks_usec())
	var s := ClientSettings.new()
	s.sensitivity = 0.27; s.fov = 95.0; s.master_volume = 0.6; s.invert_y = true
	s.save_to(path)
	var s2 := ClientSettings.new()
	s2.load_from(path)
	assert_almost_eq(s2.sensitivity, 0.27, 0.0001)
	assert_almost_eq(s2.fov, 95.0, 0.0001)
	assert_almost_eq(s2.master_volume, 0.6, 0.0001)
	assert_true(s2.invert_y)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_defaults_when_file_missing() -> void:
	var s := ClientSettings.new()
	s.load_from("user://does_not_exist_%d.cfg" % Time.get_ticks_usec())
	assert_true(s.fov > 0.0 and s.sensitivity > 0.0, "sane defaults")

extends TestCase
## Loadout-UI redesign Task 1: ClientSettings persists a per-class loadout map (class-id STRING ->
## loadout dict) to settings.cfg so choices stick across matches AND servers. Round-trips through the
## ConfigFile, ignores malformed data, and hands out deep copies (no aliasing of the live store).

func _sample() -> Dictionary:
	return {
		"class": Loadout.ASSAULT, "primary": 17, "secondary": Weapon.PISTOL,
		"gadget": Loadout.GADGET_C4, "armor": Armor.HEAVY, "grenade": Grenade.SMOKE,
		"attachments": {"optic": "red_dot", "barrel": "standard", "underbarrel": "none_ub"},
	}

func test_class_loadouts_roundtrip_save_load() -> void:
	var path := "user://test_loadouts_%d.cfg" % Time.get_ticks_usec()
	var s := ClientSettings.new()
	s.set_class_loadout(Loadout.ASSAULT, _sample())
	var medic := _sample(); medic["class"] = Loadout.MEDIC; medic["armor"] = Armor.LIGHT
	s.set_class_loadout(Loadout.MEDIC, medic)
	s.save_to(path)

	var s2 := ClientSettings.new()
	s2.load_from(path)
	var a := s2.get_class_loadout(Loadout.ASSAULT)
	assert_eq(int(a.get("primary", -1)), 17, "primary preserved through JSON round trip")
	assert_eq(int(a.get("armor", -1)), Armor.HEAVY, "armor preserved")
	assert_eq(String((a.get("attachments", {}) as Dictionary).get("optic", "")), "red_dot",
		"nested attachments preserved")
	assert_eq(int(s2.get_class_loadout(Loadout.MEDIC).get("class", -1)), Loadout.MEDIC,
		"second class preserved independently")
	assert_eq(int(s2.get_class_loadout(Loadout.MEDIC).get("armor", -1)), Armor.LIGHT)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_missing_section_returns_empty() -> void:
	var s := ClientSettings.new()
	s.load_from("user://does_not_exist_%d.cfg" % Time.get_ticks_usec())
	assert_true(s.get_class_loadout(Loadout.ASSAULT).is_empty(), "no file -> {} for every class")

func test_garbage_section_ignored_no_crash() -> void:
	tolerate_runtime_errors()   # JSON.parse_string on the malformed entry pushes an expected engine error
	var path := "user://test_loadouts_bad_%d.cfg" % Time.get_ticks_usec()
	var cf := ConfigFile.new()
	cf.set_value("loadouts", "0", "{not valid json")   # malformed JSON string
	cf.set_value("loadouts", "1", 12345)               # non-string value
	cf.save(path)
	var s := ClientSettings.new()
	s.load_from(path)   # must not crash
	assert_true(s.get_class_loadout(Loadout.ASSAULT).is_empty(), "malformed entry -> {}")
	assert_true(s.get_class_loadout(Loadout.MEDIC).is_empty(), "non-string entry -> {}")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_set_get_return_deep_copies() -> void:
	var s := ClientSettings.new()
	var cfg := _sample()
	s.set_class_loadout(Loadout.ASSAULT, cfg)
	# Mutating the caller's dict (incl. its nested attachments) must not reach the store.
	cfg["primary"] = 999
	(cfg["attachments"] as Dictionary)["optic"] = "TAMPER"
	var got := s.get_class_loadout(Loadout.ASSAULT)
	assert_eq(int(got.get("primary", -1)), 17, "set() stored a deep copy, not an alias")
	assert_eq(String((got.get("attachments", {}) as Dictionary).get("optic", "")), "red_dot")
	# And mutating the returned dict must not reach the store either.
	got["primary"] = 111
	assert_eq(int(s.get_class_loadout(Loadout.ASSAULT).get("primary", -1)), 17,
		"get() returned a deep copy")

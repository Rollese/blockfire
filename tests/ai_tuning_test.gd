extends TestCase
const Tuning := preload("res://bots/ai/tuning.gd")

func test_loads_profiles() -> void:
	var t := Tuning.load_file("res://data/ai_tuning.json")
	assert_true(t.has("profiles"), "tuning has profiles")
	assert_true(t["profiles"].has("regular"), "regular profile present")

func test_profile_has_required_knobs() -> void:
	var t := Tuning.load_file("res://data/ai_tuning.json")
	var p: Dictionary = t["profiles"]["regular"]
	assert_true(p.has("reaction_delay_ticks"), "reaction delay knob")
	assert_true(p.has("aim_error_deg"), "aim error knob")
	assert_true(p.has("aggression"), "aggression scalar")

func test_weights_block_has_all_behaviour_keys() -> void:
	# M7.5-P3: the five original keys plus the three support behaviours.
	var t := Tuning.load_file("res://data/ai_tuning.json")
	var w: Dictionary = t.get("weights", {})
	for k in ["retreat", "take_cover", "suppress", "engage", "push_obj", "revive", "seek_supply", "avoid_danger"]:
		assert_true(w.has(k), "weights block has %s" % k)

func test_weights_original_values_unchanged() -> void:
	# Regression: the original five must keep their historical hardcoded values so
	# file-driven scoring stays bit-identical (take_cover is the formula coefficient).
	var t := Tuning.load_file("res://data/ai_tuning.json")
	var w: Dictionary = t.get("weights", {})
	assert_almost_eq(float(w.get("retreat", 0.0)), 1.6, 1e-9, "retreat 1.6")
	assert_almost_eq(float(w.get("take_cover", 0.0)), 1.0, 1e-9, "take_cover coefficient 1.0")
	assert_almost_eq(float(w.get("suppress", 0.0)), 0.4, 1e-9, "suppress 0.4")
	assert_almost_eq(float(w.get("engage", 0.0)), 0.7, 1e-9, "engage 0.7")
	assert_almost_eq(float(w.get("push_obj", 0.0)), 0.2, 1e-9, "push_obj 0.2")

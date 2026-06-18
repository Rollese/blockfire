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

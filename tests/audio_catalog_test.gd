extends TestCase

func _cat() -> AudioCatalog:
	var c := AudioCatalog.new()
	c.load_from("res://data/sounds.json")
	return c

func test_loads_known_event_def() -> void:
	var def := _cat().def_for("gunfire")
	assert_eq(def["bus"], "SFX", "gunfire routes to SFX")
	assert_eq(int(def["priority"]), 2, "gunfire is HIGH priority")
	assert_true(float(def["max_distance"]) > 0.0, "gunfire is spatial")

func test_suppressed_has_smaller_signature() -> void:
	var c := _cat()
	assert_true(float(c.def_for("gunfire_supp")["max_distance"]) < float(c.def_for("gunfire")["max_distance"]),
		"suppressed weapon has a smaller audible radius")

func test_unknown_type_returns_safe_fallback() -> void:
	var def := _cat().def_for("does_not_exist")
	assert_true(def.has("bus") and def.has("priority"), "fallback is a usable def")

func test_2d_events_flagged_nonspatial() -> void:
	assert_true(_cat().is_spatial("gunfire"), "world sound is spatial")
	assert_false(_cat().is_spatial("hitmarker"), "max_distance==0 -> non-spatial UI")

func test_validate_rejects_malformed_entries() -> void:
	var c := AudioCatalog.new()
	var errs := c.validate([
		{"type": "ok",  "bus": "SFX", "priority": 1, "gain_db": 0.0, "unit_size": 4.0, "max_distance": 100.0, "cutoff_hz": 20000.0, "stream": "x"},
		{"type": "bad_prio", "bus": "SFX", "priority": 9, "gain_db": 0.0, "unit_size": 4.0, "max_distance": 100.0, "cutoff_hz": 20000.0, "stream": "x"},
		{"type": "bad_unit", "bus": "SFX", "priority": 1, "gain_db": 0.0, "unit_size": 0.0, "max_distance": 100.0, "cutoff_hz": 20000.0, "stream": "x"},
		{"type": "bad_bus",  "bus": "NOPE", "priority": 1, "gain_db": 0.0, "unit_size": 4.0, "max_distance": 100.0, "cutoff_hz": 20000.0, "stream": "x"},
	], ["SFX", "UI", "Listener"])
	assert_eq(errs.size(), 3, "three malformed entries reported, the valid one passes")

func test_real_catalog_validates_clean() -> void:
	var c := _cat()
	assert_eq(c.errors.size(), 0, "shipped data/sounds.json has no validation errors")

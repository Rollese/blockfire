extends TestCase

func _cat() -> VehicleCatalog:
	return VehicleCatalog.load_file("res://data/vehicles.json")

func test_loads_transport() -> void:
	var c := _cat()
	assert_true(c != null)
	assert_eq(c.size(), 1)
	assert_eq(c.index_of("transport"), 0)

func test_def_has_stats_and_seats() -> void:
	var d: Dictionary = _cat().def_of(0)
	assert_eq(int(d["max_hp"]), 1000)
	assert_almost_eq(float(d["max_speed"]), 18.0, 0.001)
	assert_eq((d["seats"] as Array).size(), 5)

func test_index_of_unknown_is_negative() -> void:
	assert_eq(_cat().index_of("nope"), -1)

extends TestCase

const VALID := '{"pieces":[{"id":"sandbag","height":"half","health":150,"blocks":"both"},{"id":"wall","height":"full","health":350,"blocks":"both"}]}'

func test_loads_valid_catalog() -> void:
	var r := PieceCatalog.from_json_string(VALID)
	assert_true(r["ok"], r["error"])
	var c: PieceCatalog = r["catalog"]
	assert_eq(c.size(), 2)
	assert_eq(c.is_half(0), true)    # sandbag
	assert_eq(c.is_half(1), false)   # wall
	assert_eq(c.health_of(1), 350)
	assert_eq(c.name_of(0), "sandbag")

func test_rejects_empty_pieces() -> void:
	assert_eq(PieceCatalog.from_json_string('{"pieces":[]}')["ok"], false)

func test_rejects_bad_height() -> void:
	assert_eq(PieceCatalog.from_json_string('{"pieces":[{"id":"x","height":"tall","health":10,"blocks":"both"}]}')["ok"], false)

func test_rejects_bad_health() -> void:
	assert_eq(PieceCatalog.from_json_string('{"pieces":[{"id":"x","height":"full","health":0,"blocks":"both"}]}')["ok"], false)

func test_rejects_duplicate_id() -> void:
	assert_eq(PieceCatalog.from_json_string('{"pieces":[{"id":"x","height":"full","health":10,"blocks":"both"},{"id":"x","height":"half","health":10,"blocks":"both"}]}')["ok"], false)

func test_material_parsed_from_json() -> void:
	var res := PieceCatalog.from_json_string('{"pieces":[{"id":"plank","height":"half","health":100,"material":"WOOD"}]}')
	assert_true(res["ok"], "valid material parses")
	var cat: PieceCatalog = res["catalog"]
	assert_eq(cat.material_of(0), PieceCatalog.MAT_WOOD)

func test_material_defaults_to_concrete() -> void:
	var res := PieceCatalog.from_json_string('{"pieces":[{"id":"x","height":"full","health":100}]}')
	assert_eq((res["catalog"] as PieceCatalog).material_of(0), PieceCatalog.MAT_CONCRETE)

func test_unknown_material_rejected() -> void:
	var res := PieceCatalog.from_json_string('{"pieces":[{"id":"x","height":"full","health":100,"material":"FOAM"}]}')
	assert_false(res["ok"], "unknown material is rejected")

func test_penetration_factors_wood() -> void:
	assert_true(PieceCatalog.is_penetrable(PieceCatalog.MAT_WOOD))
	assert_almost_eq(PieceCatalog.absorption_of(PieceCatalog.MAT_WOOD), 0.40, 0.001)
	assert_almost_eq(PieceCatalog.transmit_of(PieceCatalog.MAT_WOOD), 0.60, 0.001)

func test_penetration_factors_concrete_blocks() -> void:
	assert_false(PieceCatalog.is_penetrable(PieceCatalog.MAT_CONCRETE))
	assert_false(PieceCatalog.is_penetrable(PieceCatalog.MAT_METAL_THICK))

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

func test_chunk_and_damage_fields_parse_with_defaults() -> void:
	var res := PieceCatalog.from_json_string('{"pieces":[{"id":"wall","height":"full","health":350,"material":"CONCRETE"}]}')
	assert_true(res["ok"])
	var c: PieceCatalog = res["catalog"]
	assert_eq(c.chunk_grid_of(0), 1)                         # default
	assert_eq(c.is_structural(0), false)                     # default
	assert_true(c.takes_damage(0, PieceCatalog.SRC_BULLET))  # default: all sources
	assert_true(c.takes_damage(0, PieceCatalog.SRC_EXPLOSIVE))

func test_explicit_chunk_and_damage_fields() -> void:
	var res := PieceCatalog.from_json_string('{"pieces":[{"id":"bwall","height":"full","health":800,"material":"CONCRETE","chunk_grid":8,"structural":true,"damage":["explosive","melee"]}]}')
	assert_true(res["ok"])
	var c: PieceCatalog = res["catalog"]
	assert_eq(c.chunk_grid_of(0), 8)
	assert_eq(c.is_structural(0), true)
	assert_false(c.takes_damage(0, PieceCatalog.SRC_BULLET), "building wall is bullet-immune")
	assert_true(c.takes_damage(0, PieceCatalog.SRC_EXPLOSIVE))
	assert_true(c.takes_damage(0, PieceCatalog.SRC_MELEE))

func test_rejects_bad_chunk_grid_and_damage() -> void:
	assert_false(PieceCatalog.from_json_string('{"pieces":[{"id":"w","height":"full","health":1,"chunk_grid":3}]}')["ok"], "chunk_grid must be 1,2,4,8")
	assert_false(PieceCatalog.from_json_string('{"pieces":[{"id":"w","height":"full","health":1,"damage":["lasers"]}]}')["ok"], "unknown damage source")

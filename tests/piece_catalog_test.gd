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

func test_fortifications_are_chunked_and_bullet_vulnerable() -> void:
	var c := PieceCatalog.load_file("res://pieces/pieces.json")
	assert_true(c != null)
	# sandbag (0) and wall (1) are the player fortifications — bullet-vulnerable, non-structural
	for t in [0, 1]:
		assert_eq(c.chunk_grid_of(t), 8, "player pieces are 8x8 chunked")
		assert_true(c.takes_damage(t, PieceCatalog.SRC_BULLET), "player pieces keep M4 bullet damage")
		assert_false(c.is_structural(t), "player pieces are non-structural")

func test_building_pieces_are_explosive_melee_only() -> void:
	var cat := PieceCatalog.load_file("res://pieces/pieces.json")
	assert_true(cat != null, "unified catalog loads")
	var bwall := -1
	for i in cat.size():
		if cat.name_of(i) == "bwall":
			bwall = i
	assert_true(bwall >= 0, "bwall present in catalog")
	assert_false(cat.takes_damage(bwall, PieceCatalog.SRC_BULLET), "building wall is bullet-immune")
	assert_true(cat.takes_damage(bwall, PieceCatalog.SRC_EXPLOSIVE), "building wall takes explosive")
	assert_true(cat.takes_damage(bwall, PieceCatalog.SRC_MELEE), "building wall takes melee")
	assert_true(cat.is_structural(bwall), "bwall is structural")

func test_catalog_index_order_is_stable() -> void:
	var cat := PieceCatalog.load_file("res://pieces/pieces.json")
	assert_eq(cat.name_of(0), "sandbag", "index 0 stays sandbag")
	assert_eq(cat.name_of(1), "wall", "index 1 stays wall (player fortification)")
	assert_eq(cat.name_of(8), "brailing", "index 8 stays brailing (chunk_grid 4)")
	assert_eq(cat.name_of(9), "prop_crate", "index 9 stays prop_crate (chunk_grid 1)")

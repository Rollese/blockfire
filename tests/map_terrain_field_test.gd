extends TestCase
const MapDef := preload("res://shared/sim/map_def.gd")

const _BASE := '"points":[{"id":"A","pos":[0,0,0],"radius":10}],"bases":[{"team":0,"pos":[-5,0,0],"radius":5},{"team":1,"pos":[5,0,0],"radius":5}]'

func test_map_without_terrain_is_empty_dict() -> void:
	var res := MapDef.from_json_string('{"name":"flat","world_half":100,%s}' % _BASE)
	assert_true(res["ok"], "parses")
	assert_true((res["map"].terrain as Dictionary).is_empty(), "no terrain field -> {}")

func test_terrain_field_parsed() -> void:
	var j := '{"name":"t","world_half":100,"terrain":{"heightmap":"heightmaps/t.png","sample_spacing":2.0,"height_min":-3.0,"height_scale":40.0},%s}' % _BASE
	var res := MapDef.from_json_string(j)
	assert_true(res["ok"], "parses")
	var t: Dictionary = res["map"].terrain
	assert_eq(String(t["heightmap"]), "heightmaps/t.png", "heightmap path")
	assert_almost_eq(float(t["sample_spacing"]), 2.0, 0.001, "spacing")
	assert_almost_eq(float(t["height_min"]), -3.0, 0.001, "height_min")
	assert_almost_eq(float(t["height_scale"]), 40.0, 0.001, "height_scale")

func test_building_terrain_cutout_flag() -> void:
	var j := '{"name":"t","world_half":100,"buildings":[{"prefab":"tunnel","origin_cell":[0,0,0],"terrain_cutout":true},{"prefab":"house","origin_cell":[5,0,5]}],%s}' % _BASE
	var res := MapDef.from_json_string(j)
	assert_true(res["ok"], "parses")
	assert_true(bool(res["map"].buildings[0]["terrain_cutout"]), "tunnel is a cutout")
	assert_false(bool(res["map"].buildings[1].get("terrain_cutout", false)), "house is not")

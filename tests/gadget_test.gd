extends TestCase

const VALID := '{"gadgets":[' + \
	'{"id":"c4","kind":"c4","max_active":2,"pawn_damage":120,"pawn_radius":5.0,"struct_damage":300,"struct_radius":4.0},' + \
	'{"id":"claymore","kind":"mine","max_active":2,"pawn_damage":100,"pawn_radius":4.0,"trigger_radius":1.5,"place_range":2.0,"arm_delay_ticks":60,"directional":true},' + \
	'{"id":"rpg","kind":"rpg","max_active":2,"ammo":3,"pawn_damage":100,"pawn_radius":6.0,"struct_damage":250,"struct_radius":4.0,"cooldown_ticks":120,"rocket_speed":150},' + \
	'{"id":"medkit","kind":"heal","give_range":3.0,"active_rate":2,"bag_pool":300,"bag_radius":3.0,"max_bags":1},' + \
	'{"id":"ammobag","kind":"ammo","give_range":3.0,"active_rate":30,"bag_pool":8,"bag_radius":3.0,"max_bags":1}]}'

func test_loads_valid_catalog() -> void:
	var res := Gadget.from_json_string(VALID)
	assert_true(res["ok"], res["error"])

func test_rejects_unknown_kind() -> void:
	assert_false(Gadget.from_json_string('{"gadgets":[{"id":"x","kind":"laser"}]}')["ok"])

func test_def_lookup_by_kind() -> void:
	var cat: Gadget = Gadget.from_json_string(VALID)["catalog"]
	assert_eq(int(cat.def_of_kind(Gadget.KIND_C4)["max_active"]), 2)
	assert_almost_eq(float(cat.def_of_kind(Gadget.KIND_HEAL)["give_range"]), 3.0, 0.001)

func test_cone_hits_enemy_in_front() -> void:
	assert_true(Gadget.in_cone(Vector3.ZERO, Vector3(0, 0, 1), Vector3(0, 0, 1.0), 1.5, deg_to_rad(60.0)))

func test_cone_misses_enemy_behind() -> void:
	assert_false(Gadget.in_cone(Vector3.ZERO, Vector3(0, 0, 1), Vector3(0, 0, -1.0), 1.5, deg_to_rad(60.0)))

func test_cone_misses_out_of_range() -> void:
	assert_false(Gadget.in_cone(Vector3.ZERO, Vector3(0, 0, 1), Vector3(0, 0, 5.0), 1.5, deg_to_rad(60.0)))

func test_give_hits_teammate_in_range() -> void:
	assert_true(Gadget.give_hits(Vector3(0, 1.6, 0), Vector3(0, 0, 1), Vector3(0, 0, 2.0), Stance.STAND, 3.0))

func test_give_misses_out_of_range() -> void:
	assert_false(Gadget.give_hits(Vector3(0, 1.6, 0), Vector3(0, 0, 1), Vector3(0, 0, 10.0), Stance.STAND, 3.0))

func test_decrement_pool_clamps_at_zero() -> void:
	assert_eq(Gadget.decrement_pool(5, 3), 2)
	assert_eq(Gadget.decrement_pool(2, 5), 0)

func test_rpg_def_has_three_rockets() -> void:
	var g: Gadget = Gadget.from_json_string(VALID)["catalog"]
	assert_eq(int(g.def_of_kind(Gadget.KIND_RPG)["ammo"]), 3)

func test_rpg_rocket_speed_is_fast_direct_fire() -> void:
	var g: Gadget = Gadget.from_json_string(VALID)["catalog"]
	assert_eq(int(g.def_of_kind(Gadget.KIND_RPG)["rocket_speed"]), 150)

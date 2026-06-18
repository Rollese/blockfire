extends TestCase

const Bot := preload("res://bots/bot_driver.gd")
const VC := preload("res://bots/ai/behaviors/vehicle_crew.gd")

func test_place_damage_remove_mirror() -> void:
	var s := {}
	VC.apply_structure_delta(s, {"op": Protocol.OP_PLACE, "rec": {"id": 5, "bucket": 3}})
	assert_eq(s.has(5), true)
	VC.apply_structure_delta(s, {"op": Protocol.OP_DAMAGE, "id": 5, "bucket": 1})
	assert_eq(s.has(5), true)          # damage must NOT erase
	assert_eq(s[5]["bucket"], 1)
	VC.apply_structure_delta(s, {"op": Protocol.OP_REMOVE, "id": 5})
	assert_eq(s.has(5), false)

func test_damage_on_unknown_id_is_noop() -> void:
	var s := {}
	VC.apply_structure_delta(s, {"op": Protocol.OP_DAMAGE, "id": 9, "bucket": 0})
	assert_eq(s.has(9), false)

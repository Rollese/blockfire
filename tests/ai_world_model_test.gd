extends TestCase
const WorldModel := preload("res://bots/ai/world_model.gd")
func test_defaults_are_empty() -> void:
	var w := WorldModel.new()
	assert_eq(w.enemies.size(), 0, "no enemies by default")
	assert_eq(w.allies.size(), 0, "no allies by default")
	assert_eq(w.downed_allies.size(), 0, "no downed by default")
	assert_almost_eq(w.incoming_fire, 0.0, 0.001, "no pressure by default")
func test_holds_assigned_fields() -> void:
	var w := WorldModel.new()
	w.now_tick = 42
	w.enemies.append({"id": 7, "pos": Vector3(1, 0, 2), "stance": 0, "dist": 3.0, "last_seen_tick": 42})
	assert_eq(w.now_tick, 42)
	assert_eq(int(w.enemies[0]["id"]), 7, "enemy record stored")

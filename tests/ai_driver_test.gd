extends TestCase
const AiDriver := preload("res://bots/ai/ai_driver.gd")

func _es(team: int, pos: Vector3, alive := true, downed := false) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = alive; e.is_downed = downed; e.stance = 0; e.health = 100
	return e

func test_decide_returns_intent_with_movement_and_buttons() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var me := _es(0, Vector3.ZERO)
	var view := {1: me, 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100)
	var intent := ai.decide(1, view, {}, {}, [], 100 + 20)
	assert_true(intent.has("move_x"), "intent carries movement")
	assert_true(intent.has("yaw"), "intent carries aim yaw")
	assert_true(intent.has("buttons"), "intent carries buttons")

func test_fresh_enemy_is_not_engaged_due_to_reaction_gate() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var me := _es(0, Vector3.ZERO)
	var view := {1: me, 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100)
	var intent := ai.decide(1, view, {}, {}, [], 100)
	assert_false(String(intent["behavior"]) == "engage", "reaction gate defers engagement")

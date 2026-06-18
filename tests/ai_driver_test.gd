extends TestCase
const AiDriver := preload("res://bots/ai/ai_driver.gd")

func _es(team: int, pos: Vector3, alive := true, downed := false, hp := 100) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = alive; e.is_downed = downed; e.stance = 0; e.health = hp
	return e

func test_decide_returns_intent_with_required_keys() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100)
	var intent := ai.decide()
	for k in ["move_x", "move_y", "yaw", "pitch", "buttons", "stance", "behavior"]:
		assert_true(intent.has(k), "intent carries %s" % k)

func test_fresh_enemy_is_not_engaged_due_to_reaction_gate() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100)   # first sighting, same tick
	var intent := ai.decide()
	assert_false(String(intent["behavior"]) == "engage", "reaction gate defers engagement")

func test_engages_and_fires_after_reaction_gate_clears() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100)        # first sighting
	ai.observe(1, view, {}, {}, [], 112)        # 12 ticks > 9 reaction delay -> gate cleared
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "engage", "healthy + calm + actionable target -> engage")
	assert_true(int(intent["buttons"]) & InputCommand.BTN_FIRE != 0, "fires once engaged")

func test_takes_cover_when_taking_damage() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var enemy := _es(1, Vector3(10, 0, 0))
	ai.observe(1, {1: _es(0, Vector3.ZERO, true, false, 100), 2: enemy}, {}, {}, [], 100)  # full HP
	ai.observe(1, {1: _es(0, Vector3.ZERO, true, false, 60), 2: enemy}, {}, {}, [], 101)   # dropped 40 HP -> pressure
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "take_cover", "health drop raises pressure -> take_cover")
	assert_eq(int(intent["stance"]), Stance.CROUCH, "crouch under fire")

extends TestCase
const Perception := preload("res://bots/ai/perception.gd")
func _es(team: int, pos: Vector3) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = true; e.stance = 0
	return e
func test_enemy_not_actionable_before_reaction_delay() -> void:
	assert_false(Perception.is_actionable(100, 108, 9), "8 ticks < 9 delay -> not yet actionable")
func test_enemy_actionable_after_reaction_delay() -> void:
	assert_true(Perception.is_actionable(100, 109, 9), "exactly 9 ticks elapsed -> actionable")
	assert_true(Perception.is_actionable(100, 200, 9), "long-visible enemy stays actionable")

func test_instance_reaction_delay_gates_per_profile() -> void:
	# M7.5-P3 (§E): the gate honors the injected per-profile delay (was hardcoded 9 for
	# every profile — recruit/elite reacted identically). Same sighting timeline, two delays.
	var recruit := Perception.new()
	recruit.reaction_delay_ticks = 15   # data/ai_tuning.json recruit value
	var elite := Perception.new()
	elite.reaction_delay_ticks = 4      # data/ai_tuning.json elite value
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	recruit.build(1, view, {}, {}, [], 100)
	elite.build(1, view, {}, {}, [], 100)
	assert_false(recruit.actionable(2, 105), "recruit (15) still gated 5 ticks after sighting")
	assert_true(elite.actionable(2, 105), "elite (4) already actionable 5 ticks after sighting")
	assert_true(recruit.actionable(2, 115), "recruit actionable once its 15-tick delay elapses")

func test_default_instance_delay_matches_historical_const() -> void:
	var p := Perception.new()
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	p.build(1, view, {}, {}, [], 100)
	assert_false(p.actionable(2, 108), "default delay stays 9 (regression)")
	assert_true(p.actionable(2, 109), "default delay stays 9 (regression)")

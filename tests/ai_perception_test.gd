extends TestCase
const Perception := preload("res://bots/ai/perception.gd")
const WorldModel := preload("res://bots/ai/world_model.gd")
func _es(team: int, pos: Vector3, alive := true, downed := false) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = alive; e.is_downed = downed; e.stance = 0
	return e
func test_build_partitions_enemies_allies_downed() -> void:
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var view := {
		1: me,
		2: _es(1, Vector3(5, 0, 0)),
		3: _es(0, Vector3(2, 0, 0)),
		4: _es(0, Vector3(3, 0, 0), true, true),
		5: _es(1, Vector3(9, 0, 0), false),
	}
	var w := p.build(1, view, {}, {}, [], 100)
	assert_eq(w.enemies.size(), 1, "one alive enemy")
	assert_eq(w.allies.size(), 1, "one alive non-downed ally")
	assert_eq(w.downed_allies.size(), 1, "one downed ally")
func test_build_applies_reaction_gate_on_first_sighting() -> void:
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var view := {1: me, 2: _es(1, Vector3(5, 0, 0))}
	var w0 := p.build(1, view, {}, {}, [], 100)
	assert_eq(w0.enemies.size(), 1)
	assert_false(p.actionable(2, 100), "freshly-seen enemy gated by reaction delay")
	assert_true(p.actionable(2, 100 + Perception.REACTION_DELAY_TICKS), "actionable after delay")

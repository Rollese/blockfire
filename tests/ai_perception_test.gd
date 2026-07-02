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
func test_enemy_record_carries_hp_frac_for_target_priority() -> void:
	# Regression: pick_target blends hp_frac, but Perception used to omit it, collapsing target
	# selection to nearest-only. Verify the enemy record now carries the real health fraction.
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var wounded := _es(1, Vector3(5, 0, 0)); wounded.health = 30
	var w := p.build(1, {1: me, 2: wounded}, {}, {}, [], 100)
	assert_eq(w.enemies.size(), 1, "one alive enemy")
	assert_almost_eq(float(w.enemies[0].get("hp_frac", -1.0)), 0.30, 0.001, "enemy record carries hp_frac from replicated health")

func test_pick_target_prefers_wounded_over_closer_healthy() -> void:
	# With hp_frac populated, a badly-wounded farther enemy outranks a closer full-HP one.
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var close_full := _es(1, Vector3(5, 0, 0)); close_full.health = 100
	var far_wounded := _es(1, Vector3(20, 0, 0)); far_wounded.health = 10
	var w := p.build(1, {1: me, 2: close_full, 3: far_wounded}, {}, {}, [], 100)
	assert_eq(AiCombat.pick_target(w), 3, "wounded enemy prioritized over closer healthy one")

func test_downed_enemy_excluded_from_enemies() -> void:
	# Regression: downed pawns keep alive==true, and their near-zero hp made them the
	# TOP-priority target (immune body soaks fire while the reviver goes unshot).
	# Mirrors the reflex-loop fix in bot_driver (12ba707) that never reached Perception.
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var downed_enemy := _es(1, Vector3(5, 0, 0), true, true); downed_enemy.health = 1
	var alive_enemy := _es(1, Vector3(20, 0, 0)); alive_enemy.health = 100
	var w := p.build(1, {1: me, 2: downed_enemy, 3: alive_enemy}, {}, {}, [], 100)
	assert_eq(w.enemies.size(), 1, "downed enemy filtered out of targetable enemies")
	assert_eq(int(w.enemies[0]["id"]), 3, "the alive enemy is the only candidate")

func test_build_applies_reaction_gate_on_first_sighting() -> void:
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var view := {1: me, 2: _es(1, Vector3(5, 0, 0))}
	var w0 := p.build(1, view, {}, {}, [], 100)
	assert_eq(w0.enemies.size(), 1)
	assert_false(p.actionable(2, 100), "freshly-seen enemy gated by reaction delay")
	assert_true(p.actionable(2, 100 + Perception.REACTION_DELAY_TICKS), "actionable after delay")

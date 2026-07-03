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

func test_priority_set_when_enemy_threatens_downed_ally() -> void:
	# M7.5-P3 (§E): `priority` was consumed by pick_target but never populated. An enemy
	# within 15m of one of MY downed allies threatens the revive -> 0.5; others 0.0.
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var downed := _es(0, Vector3(10, 0, 0), true, true)
	var threat := _es(1, Vector3(12, 0, 0))     # 2m from the downed ally
	var far := _es(1, Vector3(40, 0, 0))        # 30m away — no threat
	var w := p.build(1, {1: me, 2: downed, 3: threat, 4: far}, {}, {}, [], 100)
	assert_eq(w.enemies.size(), 2, "two alive enemies")
	for e in w.enemies:
		if int(e["id"]) == 3:
			assert_almost_eq(float(e.get("priority", -1.0)), 0.5, 0.001, "revive-threatening enemy tagged 0.5")
		else:
			assert_almost_eq(float(e.get("priority", -1.0)), 0.0, 0.001, "distant enemy priority 0.0")

func test_priority_zero_without_downed_allies() -> void:
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var w := p.build(1, {1: me, 2: _es(1, Vector3(5, 0, 0))}, {}, {}, [], 100)
	assert_almost_eq(float(w.enemies[0].get("priority", -1.0)), 0.0, 0.001, "no downed allies -> priority 0.0")

func test_pick_target_prefers_revive_threat_over_closer_enemy() -> void:
	# End-to-end: the populated priority actually changes target selection.
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var downed := _es(0, Vector3(0, 0, 30), true, true)
	var closer := _es(1, Vector3(5, 0, 0))     # 5m from me, ~30m from the downed ally (no tag)
	var threat := _es(1, Vector3(0, 0, 29))    # 1m from the downed ally, 29m from me
	var w := p.build(1, {1: me, 2: downed, 3: closer, 4: threat}, {}, {}, [], 100)
	assert_eq(AiCombat.pick_target(w), 4, "enemy threatening the revive outranks the closer one")

func test_last_known_returns_most_recent_memory_entry() -> void:
	# M7.5-P3 (§E): _memory was written+decayed but never read. last_known() exposes the
	# freshest remembered enemy position for the suppress-at-memory aim.
	var p := Perception.new()
	assert_true(p.last_known().is_empty(), "no memory -> {}")
	var me := _es(0, Vector3.ZERO)
	p.build(1, {1: me, 2: _es(1, Vector3(10, 0, 10))}, {}, {}, [], 100)
	p.build(1, {1: me, 3: _es(1, Vector3(-20, 0, 0))}, {}, {}, [], 105)   # newer sighting of a different enemy
	p.build(1, {1: me}, {}, {}, [], 110)   # both hidden, both within the 90-tick memory window
	var lk: Dictionary = p.last_known()
	assert_false(lk.is_empty(), "recent memory survives the enemy leaving view")
	assert_eq(lk["pos"], Vector3(-20, 0, 0), "most recent entry wins")
	assert_eq(int(lk["tick"]), 105, "carries the sighting tick")

func test_last_known_empty_after_memory_decays() -> void:
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	p.build(1, {1: me, 2: _es(1, Vector3(10, 0, 0))}, {}, {}, [], 100)
	p.build(1, {1: me}, {}, {}, [], 100 + Perception.MEMORY_DECAY_TICKS + 1)
	assert_true(p.last_known().is_empty(), "expired memory is not offered as an aim point")

func test_build_applies_reaction_gate_on_first_sighting() -> void:
	var p := Perception.new()
	var me := _es(0, Vector3.ZERO)
	var view := {1: me, 2: _es(1, Vector3(5, 0, 0))}
	var w0 := p.build(1, view, {}, {}, [], 100)
	assert_eq(w0.enemies.size(), 1)
	assert_false(p.actionable(2, 100), "freshly-seen enemy gated by reaction delay")
	assert_true(p.actionable(2, 100 + Perception.REACTION_DELAY_TICKS), "actionable after delay")

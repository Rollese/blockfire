extends TestCase
const AiDriver := preload("res://bots/ai/ai_driver.gd")

func _es(team: int, pos: Vector3, alive := true, downed := false, hp := 100) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = alive; e.is_downed = downed; e.stance = 0; e.health = hp
	return e

func test_decide_returns_intent_with_required_keys() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)
	var intent := ai.decide()
	for k in ["move_x", "move_y", "yaw", "pitch", "buttons", "stance", "behavior"]:
		assert_true(intent.has(k), "intent carries %s" % k)

func test_fresh_enemy_is_not_engaged_due_to_reaction_gate() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)   # first sighting, same tick
	var intent := ai.decide()
	assert_false(String(intent["behavior"]) == "engage", "reaction gate defers engagement")

func test_engages_and_fires_after_reaction_gate_clears() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)        # first sighting
	ai.observe(1, view, {}, {}, [], 112, Vector3.ZERO)        # 12 ticks > 9 reaction delay -> gate cleared
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "engage", "healthy + calm + actionable target -> engage")
	assert_true(int(intent["buttons"]) & InputCommand.BTN_FIRE != 0, "fires once engaged")

func test_takes_cover_when_taking_damage() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var enemy := _es(1, Vector3(10, 0, 0))
	ai.observe(1, {1: _es(0, Vector3.ZERO, true, false, 100), 2: enemy}, {}, {}, [], 100, Vector3.ZERO)  # full HP
	ai.observe(1, {1: _es(0, Vector3.ZERO, true, false, 60), 2: enemy}, {}, {}, [], 101, Vector3.ZERO)   # dropped 40 HP -> pressure
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "take_cover", "health drop raises pressure -> take_cover")
	assert_eq(int(intent["stance"]), Stance.CROUCH, "crouch under fire")
	# No structures in view -> no known cover. Must flee (break LOS), not root crouched in the open.
	assert_true(absf(float(intent["move_x"])) + absf(float(intent["move_y"])) > 0.0, "take_cover with no cover flees instead of rooting")

func test_engage_closes_distance_when_out_of_range() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(80, 0, 0))}  # 80m > ENGAGE_RANGE
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)
	ai.observe(1, view, {}, {}, [], 112, Vector3.ZERO)  # gate cleared
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "engage", "actionable target -> engage")
	assert_true(float(intent["move_x"]) > 0.5, "moves toward distant target (+x)")
	assert_true(int(intent["buttons"]) & InputCommand.BTN_FIRE == 0, "no fire out of range")

func test_engage_advances_and_fires_at_range() -> void:
	# Beyond STANDOFF_RANGE but within ENGAGE_RANGE: bot fires AND advances toward the enemy
	# (no longer roots in place — playtest 2026-06-18).
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(30, 0, 0))}  # 30m: in ENGAGE, beyond STANDOFF
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)
	ai.observe(1, view, {}, {}, [], 112, Vector3.ZERO)
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "engage")
	assert_true(int(intent["buttons"]) & InputCommand.BTN_FIRE != 0, "fires in range")
	assert_true(float(intent["move_x"]) > 0.5, "advances toward enemy at +x while firing")

func test_engage_strafes_inside_standoff() -> void:
	# Inside STANDOFF_RANGE: bot fires AND strafes laterally (perpendicular to the +x line of
	# fire => lateral z move, no forward charge) instead of standing still.
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(6, 0, 0))}  # 6m < STANDOFF_RANGE
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)
	ai.observe(1, view, {}, {}, [], 112, Vector3.ZERO)
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "engage")
	assert_true(int(intent["buttons"]) & InputCommand.BTN_FIRE != 0, "fires at standoff")
	assert_true(absf(float(intent["move_y"])) > 0.5, "strafes laterally instead of rooting")
	assert_almost_eq(float(intent["move_x"]), 0.0, 0.001, "no forward charge inside standoff")

func test_push_obj_marches_to_objective_when_no_enemy() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO)}  # no enemy -> push_obj
	ai.observe(1, view, {}, {}, [], 100, Vector3(0, 0, 100))
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "push_obj")
	assert_true(float(intent["move_y"]) > 0.5, "marches toward +z objective")

func test_suppress_holds_and_faces_fresh_enemy() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)  # fresh enemy -> engage gated -> suppress
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "suppress")
	assert_almost_eq(float(intent["move_x"]), 0.0, 0.001, "suppress holds position (x)")
	assert_almost_eq(float(intent["move_y"]), 0.0, 0.001, "suppress holds position (y)")
	assert_true(int(intent["buttons"]) & InputCommand.BTN_FIRE == 0, "no fire before reaction gate clears")

func test_decide_safe_when_self_absent_from_view() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	# my_id 1 is NOT in the view -> self_state null -> must not crash, returns a safe default intent.
	ai.observe(1, {2: _es(1, Vector3(10, 0, 0))}, {}, {}, [], 100, Vector3.ZERO)
	var intent := ai.decide()
	assert_true(intent.has("behavior"), "returns a valid intent dict even with no self")
	assert_almost_eq(float(intent["move_x"]), 0.0, 0.001, "no movement without self")

func test_aim_settles_onto_true_bearing_over_time() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	# Track the same in-range target long past the reaction gate + settle window.
	var intent := {}
	for i in 22:
		ai.observe(1, view, {}, {}, [], 100 + i)
		intent = ai.decide()
	assert_eq(String(intent["behavior"]), "engage", "stable engage on a tracked target")
	# enemy at +x (z=0): true yaw bearing = atan2(10, 0); settled jitter -> ~0
	assert_almost_eq(float(intent["yaw"]), atan2(10.0, 0.0), 0.02, "aim settles onto the true bearing")

func test_retreat_moves_toward_cover_when_critically_hurt() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var enemy := _es(1, Vector3(10, 0, 0))
	# structs dict drives cover; give one structure cell near +x. Use a structs record the
	# WorldModel build understands: {id: {"cell": Vector3i}}. Place cell so cover != self.
	var structs := {1: {"cell": Vector3i(1, 0, 0)}}
	ai.observe(1, {1: _es(0, Vector3.ZERO, true, false, 100), 2: enemy}, {}, structs, [], 100, Vector3.ZERO)
	ai.observe(1, {1: _es(0, Vector3.ZERO, true, false, 20), 2: enemy}, {}, structs, [], 101, Vector3.ZERO)  # 80 HP drop -> pressure 1.0, hp_frac 0.2
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "retreat", "critical HP under heavy fire -> retreat")
	assert_true(absf(float(intent["move_x"])) + absf(float(intent["move_y"])) > 0.0, "retreat produces movement")

func test_reset_clears_per_life_state() -> void:
	# Pre-M8-P3 regression: AI state persisted across lives (and would persist across map
	# rotations) — enemies seen in a PAST life stayed instantly actionable (skipping the
	# reaction gate), stale velocity tracks produced wild aim leads on respawn, and the
	# behaviour latch carried over. reset() is called from the bot_driver dead branch.
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)
	ai.observe(1, view, {}, {}, [], 112, Vector3.ZERO)   # reaction gate cleared
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "engage", "precondition: engaged before death")
	assert_false(ai._enemy_track.is_empty(), "precondition: velocity track populated")
	ai.reset()
	assert_true(ai._enemy_track.is_empty(), "velocity tracks dropped on reset")
	assert_eq(ai._current_behavior, "", "behaviour latch cleared")
	# Fresh life: the same enemy must re-trigger the reaction delay, not be shot instantly.
	ai.observe(1, view, {}, {}, [], 200, Vector3.ZERO)
	var intent2 := ai.decide()
	assert_false(String(intent2["behavior"]) == "engage", "reaction gate re-armed after reset")

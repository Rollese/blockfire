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

func test_push_obj_march_spread_differs_per_bot() -> void:
	# Batch 6 flank/spread: two bots pushing the same objective march on different lateral
	# lanes instead of a single-file column down the same line.
	var a := AiDriver.new(42, 0, "regular")
	var b := AiDriver.new(42, 1, "regular")
	var view := {1: _es(0, Vector3.ZERO)}
	a.observe(1, view, {}, {}, [], 100, Vector3(0, 0, 100))
	b.observe(1, view, {}, {}, [], 100, Vector3(0, 0, 100))
	var ia := a.decide()
	var ib := b.decide()
	assert_true(absf(float(ia["move_x"]) - float(ib["move_x"])) > 0.001, "different bots -> different march lanes")

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

# --- Track staleness (batch 6): velocity was computed across arbitrarily long visibility gaps,
# so an enemy reappearing far away (respawn, interest-range re-entry) produced a wild aim lead.

func test_track_velocity_from_fresh_consecutive_samples() -> void:
	var prev := {"pos": Vector3.ZERO, "tick": 100, "vel": Vector3.ZERO}
	var v := AiDriver.track_velocity(prev, Vector3(1, 0, 0), 101)
	assert_almost_eq(v.x, 1.0 / SimLoop.DT, 0.01, "1 m in 1 tick -> 30 m/s")

func test_track_velocity_zero_for_unknown_enemy() -> void:
	assert_eq(AiDriver.track_velocity(null, Vector3(5, 0, 0), 100), Vector3.ZERO)

func test_track_velocity_discards_stale_gap() -> void:
	# Enemy unseen for 100 ticks reappears 50 m away: no lead at all beats a wild one.
	var prev := {"pos": Vector3.ZERO, "tick": 100, "vel": Vector3(3, 0, 0)}
	var v := AiDriver.track_velocity(prev, Vector3(50, 0, 0), 100 + AiDriver.TRACK_STALE_TICKS + 70)
	assert_eq(v, Vector3.ZERO, "stale track -> aim at the observed position, no velocity lead")

func test_track_velocity_persists_estimate_when_target_holds_still() -> void:
	var prev := {"pos": Vector3(5, 0, 0), "tick": 100, "vel": Vector3(2, 0, 0)}
	var v := AiDriver.track_velocity(prev, Vector3(5, 0, 0), 101)
	assert_eq(v, Vector3(2, 0, 0), "no movement this tick -> keep last good estimate")

func test_reappearing_enemy_gets_no_stale_lead_in_observe() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var me := _es(0, Vector3.ZERO)
	ai.observe(1, {1: me, 2: _es(1, Vector3(10, 0, 0))}, {}, {}, [], 100, Vector3.ZERO)
	ai.observe(1, {1: me, 2: _es(1, Vector3(11, 0, 0))}, {}, {}, [], 101, Vector3.ZERO)   # moving +x
	# Enemy 2 leaves view for 200 ticks, reappears 60 m away.
	ai.observe(1, {1: me}, {}, {}, [], 200, Vector3.ZERO)
	ai.observe(1, {1: me, 2: _es(1, Vector3(0, 0, 60))}, {}, {}, [], 301, Vector3.ZERO)
	assert_eq(ai._enemy_track[2]["vel"], Vector3.ZERO, "reappearance starts a fresh track, no gap-average lead")

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

# --- M7.5-P3 (§E) inert-feature fixes: profile reaction delay, AI_TICK_EVERY cadence,
# memory-read suppress, --ai-profile flag.

func test_profile_reaction_delay_wired_into_perception() -> void:
	# The profile's reaction_delay_ticks was loaded but never applied (gate used the const).
	assert_eq(AiDriver.new(42, 0, "recruit")._perc.reaction_delay_ticks, 15, "recruit delay from tuning")
	assert_eq(AiDriver.new(42, 0, "elite")._perc.reaction_delay_ticks, 4, "elite delay from tuning")
	assert_eq(AiDriver.new(42, 0, "regular")._perc.reaction_delay_ticks, 9, "regular keeps historical 9")

func test_recruit_holds_fire_longer_than_elite_on_same_timeline() -> void:
	# Same sighting timeline, different profiles: the observable is BTN_FIRE (engage fires
	# when actionable; suppress also fires once actionable — either way the gate is the delay).
	var recruit := AiDriver.new(42, 0, "recruit")
	var elite := AiDriver.new(42, 0, "elite")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	for ai in [recruit, elite]:
		ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)
		ai.observe(1, view, {}, {}, [], 105, Vector3.ZERO)   # 5 ticks after first sighting
	assert_true(int(elite.decide()["buttons"]) & InputCommand.BTN_FIRE != 0, "elite (delay 4) fires at +5 ticks")
	assert_true(int(recruit.decide()["buttons"]) & InputCommand.BTN_FIRE == 0, "recruit (delay 15) still holds at +5")
	recruit.observe(1, view, {}, {}, [], 115, Vector3.ZERO)  # 15 ticks -> recruit's gate clears
	assert_true(int(recruit.decide()["buttons"]) & InputCommand.BTN_FIRE != 0, "recruit fires once its delay elapses")

func test_decide_cadence_caches_behavior_between_refresh_ticks() -> void:
	# AI_TICK_EVERY=3: full behaviour re-scoring runs only on the stride; between refreshes
	# decide() keeps the cached behaviour (movement/aim for it still run every call).
	var ai := AiDriver.new(42, 0, "regular")
	ai.observe(1, {1: _es(0, Vector3.ZERO)}, {}, {}, [], 100, Vector3(0, 0, 100))
	assert_eq(String(ai.decide()["behavior"]), "push_obj", "refresh tick: fresh scoring -> push_obj")
	# Tick 101: massive health drop — would flip the behaviour if scoring re-ran now.
	var enemy := _es(1, Vector3(10, 0, 0))
	ai.observe(1, {1: _es(0, Vector3.ZERO, true, false, 20), 2: enemy}, {}, {}, [], 101, Vector3(0, 0, 100))
	assert_eq(String(ai.decide()["behavior"]), "push_obj", "between refreshes the cached behaviour holds")
	# Tick 103: stride reached -> re-scoring sees the pressure and reacts.
	ai.observe(1, {1: _es(0, Vector3.ZERO, true, false, 20), 2: enemy}, {}, {}, [], 103, Vector3(0, 0, 100))
	assert_true(String(ai.decide()["behavior"]) != "push_obj", "refresh tick re-scores and reacts to damage")

func test_danger_zones_preempt_decide_cadence() -> void:
	# A grenade at your feet can't wait 2 ticks: non-empty danger_zones force a re-score.
	var ai := AiDriver.new(42, 0, "regular")
	ai.observe(1, {1: _es(0, Vector3.ZERO)}, {}, {}, [], 100, Vector3(0, 0, 100))
	assert_eq(String(ai.decide()["behavior"]), "push_obj", "precondition: push_obj cached at tick 100")
	ai.observe(1, {1: _es(0, Vector3.ZERO)}, {}, {}, [], 101, Vector3(0, 0, 100))
	# Perception does not feed danger zones until Task 6 — inject one directly (fair test
	# of decide()'s pre-empt path; the WorldModel field is the real Task 6 interface).
	ai._world.danger_zones = [{"pos": Vector3.ZERO, "radius": 8.0}]
	assert_eq(String(ai.decide()["behavior"]), "avoid_danger", "danger pre-empts the cadence, no stride wait")

func test_suppress_aims_at_last_known_when_enemy_hides() -> void:
	# §E memory read: enemy seen then hidden (within the 90-tick memory window) -> the
	# suppress branch keeps the muzzle on the remembered position instead of the stale yaw.
	var ai := AiDriver.new(42, 0, "regular")
	ai.observe(1, {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 10))}, {}, {}, [], 100, Vector3.ZERO)
	assert_eq(String(ai.decide()["behavior"]), "suppress", "fresh enemy -> gate holds -> suppress")
	ai.observe(1, {1: _es(0, Vector3.ZERO)}, {}, {}, [], 101, Vector3.ZERO)   # enemy breaks LOS
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "suppress", "cached behaviour persists while hidden")
	assert_almost_eq(float(intent["yaw"]), atan2(10.0, 10.0), deg_to_rad(5.0), "aims within 5 deg of last-known bearing")
	assert_true(int(intent["buttons"]) & InputCommand.BTN_FIRE == 0, "no blind fire at a memory")

func test_bot_driver_ai_profile_flag() -> void:
	# --ai-profile selects the difficulty profile every spawned AiDriver gets.
	var bd := BotDriver.new()
	autofree(bd)
	bd.configure({})
	assert_eq(bd._ai_profile, "regular", "default profile is regular")
	bd.configure({"ai-profile": "elite"})
	assert_eq(bd._ai_profile, "elite", "valid profile stored")

func test_bot_driver_ai_profile_unknown_falls_back() -> void:
	var bd := BotDriver.new()
	autofree(bd)
	bd.configure({"ai-profile": "nightmare"})
	assert_eq(bd._ai_profile, "regular", "unknown profile warns and falls back to regular")

extends TestCase
const Perception := preload("res://bots/ai/perception.gd")
func test_health_drop_raises_pressure() -> void:
	var p := Perception.infer_pressure(100.0, 70.0, true)
	assert_true(p > 0.5, "health loss + aimed-at -> elevated pressure")
func test_no_damage_no_aim_is_calm() -> void:
	var p := Perception.infer_pressure(100.0, 100.0, false)
	assert_almost_eq(p, 0.0, 0.001, "no loss, not aimed at -> calm")
func test_pressure_clamped_to_one() -> void:
	var p := Perception.infer_pressure(100.0, 0.0, true)
	assert_true(p <= 1.0, "pressure never exceeds 1.0")

func test_health_drop_alone() -> void:
	# 50 HP lost == PRESSURE_HP_REF, no aim -> exactly 1.0
	assert_almost_eq(Perception.infer_pressure(100.0, 50.0, false), 1.0, 0.001, "full-ref damage alone -> 1.0")

func test_aimed_at_alone() -> void:
	assert_almost_eq(Perception.infer_pressure(100.0, 100.0, true), 0.5, 0.001, "aimed-at with no damage -> 0.5")

# --- Pressure envelope (batch 6): incoming_fire was a 1-tick impulse (nonzero only on the exact
# tick health dropped), so take_cover was a single-tick twitch oscillating with engage. Pressure
# now decays geometrically instead of vanishing.

func test_decay_pressure_takes_the_larger_of_impulse_and_decayed_previous() -> void:
	assert_almost_eq(Perception.decay_pressure(0.0, 1.0), 1.0, 0.001, "fresh impulse dominates")
	assert_almost_eq(Perception.decay_pressure(1.0, 0.0), Perception.PRESSURE_DECAY, 0.001, "quiet tick decays, not resets")
	assert_almost_eq(Perception.decay_pressure(0.5, 0.8), 0.8, 0.001, "bigger new impulse replaces the tail")

func test_decay_pressure_floors_to_zero() -> void:
	var p := 1.0
	for _i in 300:
		p = Perception.decay_pressure(p, 0.0)
	assert_almost_eq(p, 0.0, 0.0001, "pressure tail eventually floors to exactly 0")

func _me_view(hp: int) -> Dictionary:
	var e := EntityState.new()
	e.team = 0; e.pos = Vector3.ZERO; e.alive = true; e.health = hp
	return {1: e}

func test_incoming_fire_persists_after_the_hit_tick() -> void:
	var perc := Perception.new()
	perc.build(1, _me_view(100), {}, {}, [], 100)                     # baseline
	var hit := perc.build(1, _me_view(60), {}, {}, [], 101)           # 40 HP drop -> impulse 0.8
	assert_almost_eq(hit.incoming_fire, 0.8, 0.001, "hit tick registers the impulse")
	var after := perc.build(1, _me_view(60), {}, {}, [], 102)         # no further damage
	assert_almost_eq(after.incoming_fire, 0.8 * Perception.PRESSURE_DECAY, 0.001,
		"pressure persists (decayed) on the tick after the hit instead of dropping to 0")

func test_reset_clears_the_pressure_envelope() -> void:
	var perc := Perception.new()
	perc.build(1, _me_view(100), {}, {}, [], 100)
	perc.build(1, _me_view(20), {}, {}, [], 101)                      # heavy hit -> pressure 1.0
	perc.reset()
	var w := perc.build(1, _me_view(100), {}, {}, [], 200)            # fresh life, full HP
	assert_almost_eq(w.incoming_fire, 0.0, 0.001, "no pressure carried into the next life")

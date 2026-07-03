extends TestCase

const Bot := preload("res://bots/bot_driver.gd")
const Obj := preload("res://bots/ai/behaviors/objective.gd")
const AiCombat := preload("res://bots/ai/behaviors/combat.gd")
const AiDrill := preload("res://bots/ai/behaviors/drill.gd")

const A := Vector3(-600, 0, -400)
const B := Vector3(-300, 0, 300)
const C := Vector3(0, 0, 0)
const D := Vector3(300, 0, -300)
const E := Vector3(600, 0, 400)

# --- choose_objective_spread: squad-hash pick among the top-k nearest capturable points.
# Replaces choose_objective_index (center==from in production neutralized its centre bias, so
# every bot targeted its nearest point and symmetric maps split into two non-meeting columns —
# the flank/spread gap from the 2026-07-02 investigation).

func test_spread_is_deterministic_for_a_squad() -> void:
	var a := Obj.choose_objective_spread([A, B, C], [-1, -1, -1], 0, Vector3.ZERO, 1)
	var b := Obj.choose_objective_spread([A, B, C], [-1, -1, -1], 0, Vector3.ZERO, 1)
	assert_eq(a, b, "same squad + same world -> same objective")

func test_spread_distributes_squads_across_top_k() -> void:
	# Three capturable points at comparable range: three squads must fan out across all three
	# instead of stacking on the single nearest.
	var pts := [Vector3(10, 0, 0), Vector3(0, 0, 12), Vector3(-14, 0, 0)]
	var picks := {}
	for squad in 3:
		picks[Obj.choose_objective_spread(pts, [-1, -1, -1], 0, Vector3.ZERO, squad)] = true
	assert_eq(picks.size(), 3, "3 squads spread across all 3 top-k points")

func test_spread_never_picks_owned_point() -> void:
	var pts := [Vector3(10, 0, 0), Vector3(0, 0, 12), Vector3(-14, 0, 0)]
	for squad in 6:
		var idx := Obj.choose_objective_spread(pts, [0, -1, -1], 0, Vector3.ZERO, squad)
		assert_ne(idx, 0, "own point never targeted while capturable points remain")

func test_spread_biases_toward_enemy_owned_point() -> void:
	# Equidistant neutral vs enemy-owned: the enemy-owned point ranks first (bias discount),
	# so squad 0 (rank 0) attacks it — pushing fights into enemy-held ground.
	var pts := [Vector3(20, 0, 0), Vector3(-20, 0, 0)]
	var idx := Obj.choose_objective_spread(pts, [-1, 1], 0, Vector3.ZERO, 0)
	assert_eq(idx, 1, "enemy-owned point outranks an equidistant neutral one")

func test_spread_defends_nearest_when_team_owns_all() -> void:
	var idx := Obj.choose_objective_spread([A, C], [0, 0], 0, Vector3(-590, 0, -390), 3)
	assert_eq(idx, 0, "owns all -> defend nearest to bot (A)")

func test_spread_empty_points_returns_negative_one() -> void:
	assert_eq(Obj.choose_objective_spread([], [], 0, Vector3.ZERO, 0), -1)

func test_spread_owners_shorter_than_points_defaults_neutral() -> void:
	var idx := Obj.choose_objective_spread([A, C], [], 0, Vector3(-590, 0, -390), 0)
	assert_true(idx == 0 or idx == 1, "missing owners default to neutral/capturable")

# --- spread_march_target: per-bot lateral offset so a squad advances as a line, not a column.

func test_march_target_offsets_laterally_and_differs_per_bot() -> void:
	var obj := Vector3(0, 0, 100)
	var t0 := Obj.spread_march_target(Vector3.ZERO, obj, 0)
	var t1 := Obj.spread_march_target(Vector3.ZERO, obj, 1)
	assert_true(t0 != t1, "different bots get different march targets")
	# March line is +z, so all spread is pure x (perpendicular), bounded by the lane width.
	assert_almost_eq(t0.z, obj.z, 0.001, "offset is perpendicular to the march line")
	assert_true(absf(t0.x) <= Obj.MARCH_SPREAD_LANES * Obj.MARCH_SPREAD_SPACING + 0.001, "offset bounded")

func test_march_target_converges_on_the_objective_up_close() -> void:
	var obj := Vector3(0, 0, 100)
	var far := Obj.spread_march_target(Vector3(0, 0, 100.0 - Obj.MARCH_CONVERGE_RANGE * 2.0), obj, 0)
	var near := Obj.spread_march_target(Vector3(0, 0, 95), obj, 0)
	assert_true(absf(near.x) < absf(far.x), "lateral offset shrinks approaching the point")
	var at := Obj.spread_march_target(obj, obj, 0)
	assert_almost_eq(at.x, obj.x, 0.001, "standing on the objective -> no offset")
	assert_almost_eq(at.z, obj.z, 0.001)

func test_combat_button_starts_burst_on_first_fire() -> void:
	var r := AiCombat.combat_button(true, 100, 0, -1)
	assert_eq(r[0], InputCommand.BTN_FIRE, "fires")
	assert_eq(r[2], 100, "burst_start set to current server tick")

func test_combat_button_keeps_firing_within_burst() -> void:
	# burst started at 100; at 100+BURST-1 still within window
	var st := 100 + AiCombat.BURST_TICKS - 1
	var r := AiCombat.combat_button(true, st, 0, 100)
	assert_eq(r[0], InputCommand.BTN_FIRE)
	assert_eq(r[2], 100, "burst_start unchanged")

func test_combat_button_reloads_when_burst_elapses() -> void:
	var st := 100 + AiCombat.BURST_TICKS
	var r := AiCombat.combat_button(true, st, 0, 100)
	assert_eq(r[0], InputCommand.BTN_RELOAD, "burst over -> reload")
	assert_eq(r[1], st + AiCombat.RELOAD_TICKS, "reload_until set")
	assert_eq(r[2], -1, "burst cleared")

func test_combat_button_holds_reload_and_does_not_fire() -> void:
	# reload_until in the future -> reload, never fire even if aim is good
	var r := AiCombat.combat_button(true, 200, 250, -1)
	assert_eq(r[0], InputCommand.BTN_RELOAD)
	assert_eq(r[1], 250, "reload_until unchanged while holding")

func test_combat_button_resumes_burst_after_reload() -> void:
	# reload finished (st >= reload_until), idle burst -> new burst + fire
	var r := AiCombat.combat_button(true, 250, 250, -1)
	assert_eq(r[0], InputCommand.BTN_FIRE)
	assert_eq(r[2], 250, "new burst starts at st")

func test_combat_button_idle_when_not_firing() -> void:
	var r := AiCombat.combat_button(false, 100, 0, -1)
	assert_eq(r[0], 0, "no button when not wanting to fire")
	assert_eq(r[1], 0); assert_eq(r[2], -1)

func test_climb_seek_steers_toward_ladder_when_objective_across() -> void:
	# Bot near the ladder base at (21,0,1), objective beyond it: steer toward the ladder base.
	var ladder := {"bottom": Vector3(21, 0, 1), "top": Vector3(21, 4, 1), "radius": 0.8}
	var steer := Obj.climb_seek(Vector3(18, 0, 1), Vector3(40, 0, 1), [ladder])
	assert_true(steer["seek"], "seeks the ladder when blocked between it and the objective")
	var far := Obj.climb_seek(Vector3(-500, 0, 0), Vector3(0, 0, 0), [ladder])
	assert_false(far["seek"], "ignores a distant ladder")

func test_climb_seek_skips_ladder_when_already_elevated() -> void:
	# A bot already up on the ledge (y well above the ladder bottom) must NOT re-seek the same
	# ladder — otherwise it gets stuck pushing "up" at the top instead of marching to the objective.
	var ladder := {"bottom": Vector3(21, 0, 1), "top": Vector3(21, 4, 1), "radius": 0.8}
	var on_ledge := Obj.climb_seek(Vector3(21, 4, 1), Vector3(40, 0, 1), [ladder])
	assert_false(on_ledge["seek"], "does not re-seek the ladder once on the ledge")

func test_drill_step_climb_then_vault() -> void:
	var ladder := {"bottom": Vector3(25, 0, 1), "top": Vector3(25, 4, 1), "radius": 1.2}
	var sandbag := Vector3(-5, 0, 1)
	# CLIMB phase, far from ladder: steer toward the base, not yet force-climbing.
	var far := AiDrill.drill_step(0, Vector3(200, 0, 1), ladder, sandbag)
	assert_eq(far["move_to"], ladder["bottom"])
	assert_false(far["force_climb"], "not force-climbing when far from the base")
	assert_eq(far["next_phase"], 0, "still climbing")
	# CLIMB phase, at the base on the ground: force-climb engaged, still climb phase.
	var atbase := AiDrill.drill_step(0, Vector3(25, 0, 1), ladder, sandbag)
	assert_true(atbase["force_climb"], "force-climb when within radius of the base")
	assert_eq(atbase["next_phase"], 0)
	# CLIMB phase, reached the top: advance to VAULT.
	var top := AiDrill.drill_step(0, Vector3(25, 4, 1), ladder, sandbag)
	assert_eq(top["next_phase"], 1, "advance to vault once at the ladder top")
	# VAULT phase, far from sandbag: steer toward it, stay in vault phase.
	var vfar := AiDrill.drill_step(1, Vector3(200, 0, 1), ladder, sandbag)
	assert_eq(vfar["move_to"], sandbag)
	assert_eq(vfar["next_phase"], 1)
	# VAULT phase, reached the sandbag: flip back to climb.
	var vnear := AiDrill.drill_step(1, Vector3(-5, 0, 1), ladder, sandbag)
	assert_eq(vnear["next_phase"], 0, "cycle back to climb after vaulting")

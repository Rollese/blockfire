extends TestCase

const Bot := preload("res://bots/bot_driver.gd")

const A := Vector3(-600, 0, -400)
const B := Vector3(-300, 0, 300)
const C := Vector3(0, 0, 0)
const D := Vector3(300, 0, -300)
const E := Vector3(600, 0, 400)

func test_prefers_central_non_owned_over_closer_corner() -> void:
	# Bot sits next to corner A, but center C is non-owned -> must pick C.
	var idx := Bot.choose_objective_index([A, C], [-1, -1], 0, Vector3(-590, 0, -390), Vector3.ZERO)
	assert_eq(idx, 1, "central point chosen over the nearer corner")

func test_skips_points_team_owns() -> void:
	# Team 0 owns C; only E is capturable.
	var idx := Bot.choose_objective_index([C, E], [0, -1], 0, Vector3.ZERO, Vector3.ZERO)
	assert_eq(idx, 1, "owned central point skipped")

func test_defends_nearest_when_team_owns_all() -> void:
	var idx := Bot.choose_objective_index([A, C], [0, 0], 0, Vector3(-590, 0, -390), Vector3.ZERO)
	assert_eq(idx, 0, "owns all -> defend nearest to bot (A)")

func test_tie_break_by_distance_from_bot() -> void:
	# B and D are equidistant from center; bot near B -> pick B.
	var idx := Bot.choose_objective_index([B, D], [-1, -1], 0, Vector3(-280, 0, 280), Vector3.ZERO)
	assert_eq(idx, 0, "equal center distance -> nearer-to-bot wins")

func test_empty_points_returns_negative_one() -> void:
	assert_eq(Bot.choose_objective_index([], [], 0, Vector3.ZERO, Vector3.ZERO), -1)

func test_owners_shorter_than_points_defaults_neutral() -> void:
	# No match-state yet (owners empty) -> all treated capturable, central wins.
	var idx := Bot.choose_objective_index([A, C], [], 0, Vector3(-590, 0, -390), Vector3.ZERO)
	assert_eq(idx, 1, "missing owners default to neutral/capturable")

func test_combat_button_starts_burst_on_first_fire() -> void:
	var r := Bot.combat_button(true, 100, 0, -1)
	assert_eq(r[0], InputCommand.BTN_FIRE, "fires")
	assert_eq(r[2], 100, "burst_start set to current server tick")

func test_combat_button_keeps_firing_within_burst() -> void:
	# burst started at 100; at 100+BURST-1 still within window
	var st := 100 + Bot.BURST_TICKS - 1
	var r := Bot.combat_button(true, st, 0, 100)
	assert_eq(r[0], InputCommand.BTN_FIRE)
	assert_eq(r[2], 100, "burst_start unchanged")

func test_combat_button_reloads_when_burst_elapses() -> void:
	var st := 100 + Bot.BURST_TICKS
	var r := Bot.combat_button(true, st, 0, 100)
	assert_eq(r[0], InputCommand.BTN_RELOAD, "burst over -> reload")
	assert_eq(r[1], st + Bot.RELOAD_TICKS, "reload_until set")
	assert_eq(r[2], -1, "burst cleared")

func test_combat_button_holds_reload_and_does_not_fire() -> void:
	# reload_until in the future -> reload, never fire even if aim is good
	var r := Bot.combat_button(true, 200, 250, -1)
	assert_eq(r[0], InputCommand.BTN_RELOAD)
	assert_eq(r[1], 250, "reload_until unchanged while holding")

func test_combat_button_resumes_burst_after_reload() -> void:
	# reload finished (st >= reload_until), idle burst -> new burst + fire
	var r := Bot.combat_button(true, 250, 250, -1)
	assert_eq(r[0], InputCommand.BTN_FIRE)
	assert_eq(r[2], 250, "new burst starts at st")

func test_combat_button_idle_when_not_firing() -> void:
	var r := Bot.combat_button(false, 100, 0, -1)
	assert_eq(r[0], 0, "no button when not wanting to fire")
	assert_eq(r[1], 0); assert_eq(r[2], -1)

func test_climb_seek_steers_toward_ladder_when_objective_across() -> void:
	# Bot near the ladder base at (21,0,1), objective beyond it: steer toward the ladder base.
	var ladder := {"bottom": Vector3(21, 0, 1), "top": Vector3(21, 4, 1), "radius": 0.8}
	var steer := Bot.climb_seek(Vector3(18, 0, 1), Vector3(40, 0, 1), [ladder])
	assert_true(steer["seek"], "seeks the ladder when blocked between it and the objective")
	var far := Bot.climb_seek(Vector3(-500, 0, 0), Vector3(0, 0, 0), [ladder])
	assert_false(far["seek"], "ignores a distant ladder")

func test_climb_seek_skips_ladder_when_already_elevated() -> void:
	# A bot already up on the ledge (y well above the ladder bottom) must NOT re-seek the same
	# ladder — otherwise it gets stuck pushing "up" at the top instead of marching to the objective.
	var ladder := {"bottom": Vector3(21, 0, 1), "top": Vector3(21, 4, 1), "radius": 0.8}
	var on_ledge := Bot.climb_seek(Vector3(21, 4, 1), Vector3(40, 0, 1), [ladder])
	assert_false(on_ledge["seek"], "does not re-seek the ladder once on the ledge")

func test_drill_step_climb_then_vault() -> void:
	var ladder := {"bottom": Vector3(25, 0, 1), "top": Vector3(25, 4, 1), "radius": 1.2}
	var sandbag := Vector3(-5, 0, 1)
	# CLIMB phase, far from ladder: steer toward the base, not yet force-climbing.
	var far := Bot.drill_step(0, Vector3(200, 0, 1), ladder, sandbag)
	assert_eq(far["move_to"], ladder["bottom"])
	assert_false(far["force_climb"], "not force-climbing when far from the base")
	assert_eq(far["next_phase"], 0, "still climbing")
	# CLIMB phase, at the base on the ground: force-climb engaged, still climb phase.
	var atbase := Bot.drill_step(0, Vector3(25, 0, 1), ladder, sandbag)
	assert_true(atbase["force_climb"], "force-climb when within radius of the base")
	assert_eq(atbase["next_phase"], 0)
	# CLIMB phase, reached the top: advance to VAULT.
	var top := Bot.drill_step(0, Vector3(25, 4, 1), ladder, sandbag)
	assert_eq(top["next_phase"], 1, "advance to vault once at the ladder top")
	# VAULT phase, far from sandbag: steer toward it, stay in vault phase.
	var vfar := Bot.drill_step(1, Vector3(200, 0, 1), ladder, sandbag)
	assert_eq(vfar["move_to"], sandbag)
	assert_eq(vfar["next_phase"], 1)
	# VAULT phase, reached the sandbag: flip back to climb.
	var vnear := Bot.drill_step(1, Vector3(-5, 0, 1), ladder, sandbag)
	assert_eq(vnear["next_phase"], 0, "cycle back to climb after vaulting")

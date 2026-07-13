extends TestCase
## M19 P4 Task 14: SUPPORT LMG-nest bot exerciser (bots/exercisers.gd maybe_lmg_nest /
## drive_mounted_nest). Proves the fleet gate physically exercises the deploy -> mount -> fire ->
## dismount loop: the pure target/seat helpers, that a captured GA_LMG_DEPLOY packet is accepted by the
## REAL server (EmplacementHarness -> ServerEmplacement.deploy), and the full deploy->mount hand-off.
##
## No sockets: bots send through a recording SpyNet; the server side runs the production
## ServerEmplacement via the same harness the emplacement_* tests use.

const BotExercisers := preload("res://bots/exercisers.gd")
const ServerFixture := preload("res://tests/server_fixture.gd")
const Protocol := preload("res://shared/net/protocol.gd")

# A Support bot id whose deterministic loadout rolls GADGET_LMG_NEST: class == SUPPORT (id % 4 == 3)
# AND the support gadget branch id % 3 == 1. id 7 satisfies both (7%4==3, 7%3==1).
const NEST_SUPPORT_ID := 7

func _es(team: int, pos: Vector3, alive := true, downed := false) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = alive; e.is_downed = downed
	return e

## A bot dict wired to a recording SpyNet, minimally populated for the LMG-nest exerciser paths.
func _make_bot(id: int, team: int, server_tick: int) -> Dictionary:
	var net := ServerFixture.SpyNet.new()
	autofree(net)
	return {
		"net": net, "peer": null, "id": id, "class": id % 4, "team": team,
		"server_tick": server_tick, "tick": server_tick, "last_seq": 0,
		"yaw": 0.0, "pitch": 0.0,
		"view": {}, "nests": [], "self_state": {},
		"lmg_deploy_last_tick": -100000, "lmg_mount_last_tick": -100000, "lmg_notarget_since": -1,
	}

func _sends_of(bot: Dictionary, msg: int) -> Array:
	return (bot["net"] as ServerFixture.SpyNet).bytes_of(msg)

# --- pure helpers -----------------------------------------------------------

func test_gadget_id_precondition() -> void:
	assert_eq(Loadout.bot_gadget(NEST_SUPPORT_ID, Loadout.SUPPORT), Loadout.GADGET_LMG_NEST,
		"id 7 Support rolls the LMG nest — the exerciser's self-gate")

func test_nearest_mountable_nest_picks_in_range_unoccupied_friendly() -> void:
	# facing +x (yaw PI/2): seat sits 0.6 m behind the pivot, so a pivot at x=2 seats at x=1.4.
	var near := {"id": 100, "pos": Vector3(2, 0, 0), "facing_yaw": PI / 2.0, "occupant": 0, "hp_frac": 1.0, "team": 0}
	var got := BotExercisers.nearest_mountable_nest([near], Vector3.ZERO, 0, 1.6)
	assert_eq(got, 100, "seat 1.4 m away is within the 1.6 m mount range")

func test_nearest_mountable_nest_skips_occupied_enemy_dead_and_far() -> void:
	var occupied := {"id": 1, "pos": Vector3(2, 0, 0), "facing_yaw": PI / 2.0, "occupant": 55, "hp_frac": 1.0, "team": 0}
	var enemy := {"id": 2, "pos": Vector3(2, 0, 0), "facing_yaw": PI / 2.0, "occupant": 0, "hp_frac": 1.0, "team": 1}
	var dead := {"id": 3, "pos": Vector3(2, 0, 0), "facing_yaw": PI / 2.0, "occupant": 0, "hp_frac": 0.0, "team": 0}
	var far := {"id": 4, "pos": Vector3(20, 0, 0), "facing_yaw": PI / 2.0, "occupant": 0, "hp_frac": 1.0, "team": 0}
	assert_eq(BotExercisers.nearest_mountable_nest([occupied, enemy, dead, far], Vector3.ZERO, 0, 1.6), 0,
		"occupied / enemy / dead / out-of-range nests are all rejected")

func test_has_friendly_nest_near() -> void:
	var nests := [{"id": 1, "pos": Vector3(5, 0, 0), "facing_yaw": 0.0, "occupant": 0, "hp_frac": 1.0, "team": 0}]
	assert_true(BotExercisers.has_friendly_nest_near(nests, Vector3.ZERO, 0, 6.0), "5 m friendly nest is 'near'")
	assert_false(BotExercisers.has_friendly_nest_near(nests, Vector3.ZERO, 0, 4.0), "beyond radius -> not near")
	assert_false(BotExercisers.has_friendly_nest_near(nests, Vector3.ZERO, 1, 6.0), "enemy nest never counts")

func test_mounted_nest_facing_lookup() -> void:
	var nests := [{"id": 9, "pos": Vector3.ZERO, "facing_yaw": 1.25, "occupant": 0, "hp_frac": 1.0, "team": 0}]
	assert_almost_eq(BotExercisers.mounted_nest_facing(nests, 9), 1.25, 0.0001, "facing looked up by id")
	assert_true(is_nan(BotExercisers.mounted_nest_facing(nests, 404)), "unknown id -> NAN (fire freely)")

# --- maybe_lmg_nest: self-gate / deploy / mount -----------------------------

func test_non_nest_gadget_bot_does_nothing() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(0, 0, 1000)   # id 0 -> Assault, gadget BREACH (not LMG nest)
	bd._ex.maybe_lmg_nest(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	assert_eq((bot["net"] as ServerFixture.SpyNet).sends.size(), 0, "self-gate: no nest packets from a non-nest bot")

func test_deploy_sent_when_enemy_ahead_and_no_nest_yet() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	var me := _es(0, Vector3.ZERO)
	bd._ex.maybe_lmg_nest(bot, me, _es(1, Vector3(10, 0, 0)))
	var deploys := _sends_of(bot, Protocol.Msg.GADGET_ACTION)
	assert_eq(deploys.size(), 1, "one deploy request sent")
	var d := Protocol.decode_gadget_action(deploys[0])
	assert_eq(int(d["action"]), Protocol.GA_LMG_DEPLOY, "it's a GA_LMG_DEPLOY")
	# Placed LMG_NEST_DEPLOY_AHEAD (2.5 m) ahead along the facing toward the enemy (+x).
	assert_almost_eq((d["pos"] as Vector3).x, bd.LMG_NEST_DEPLOY_AHEAD, 0.01, "placed ahead of the bot toward the enemy")
	assert_almost_eq((d["dir"] as Vector3).x, 1.0, 0.01, "facing the enemy (+x)")

func test_deploy_suppressed_by_cadence() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	bot["lmg_deploy_last_tick"] = 1000 - (bd.LMG_NEST_DEPLOY_COOLDOWN_TICKS - 1)   # still cooling down
	bd._ex.maybe_lmg_nest(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	assert_eq(_sends_of(bot, Protocol.Msg.GADGET_ACTION).size(), 0, "cadence gate blocks a second deploy")

func test_no_deploy_without_a_target() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	bd._ex.maybe_lmg_nest(bot, _es(0, Vector3.ZERO), null)
	assert_eq((bot["net"] as ServerFixture.SpyNet).sends.size(), 0, "no enemy ahead -> no deploy")

func test_no_redeploy_when_friendly_nest_already_near() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	# A friendly nest 5 m away (within NEAR_RADIUS) but seat well beyond mount range -> neither mount nor redeploy.
	bot["nests"] = [{"id": 1, "pos": Vector3(5, 0, 0), "facing_yaw": 0.0, "occupant": 0, "hp_frac": 1.0, "team": 0}]
	bd._ex.maybe_lmg_nest(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	assert_eq((bot["net"] as ServerFixture.SpyNet).sends.size(), 0, "own nest already nearby -> no second nest")

func test_mount_requested_when_nest_in_reach() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	# Pivot at x=2, facing +x -> seat at x=1.4, within the 1.6 m mount range of a bot at the origin.
	bot["nests"] = [{"id": 42, "pos": Vector3(2, 0, 0), "facing_yaw": PI / 2.0, "occupant": 0, "hp_frac": 1.0, "team": 0}]
	bd._ex.maybe_lmg_nest(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	var mounts := _sends_of(bot, Protocol.Msg.EMPLACEMENT_ACTION)
	assert_eq(mounts.size(), 1, "one mount request")
	var d := Protocol.decode_emplacement_action(mounts[0])
	assert_eq(int(d["action"]), Protocol.EA_MOUNT, "EA_MOUNT sent")
	assert_eq(int(d["nest_id"]), 42, "for the in-reach nest")
	assert_eq(_sends_of(bot, Protocol.Msg.GADGET_ACTION).size(), 0, "mount takes priority — no deploy this tick")

# --- drive_mounted_nest: aim+fire / dismount --------------------------------

func test_mounted_gunner_fires_at_enemy_in_arc() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	var nest_id := Emplacement.id_for(0)
	bot["self_state"] = {"mounted_nest": nest_id}
	bot["nests"] = [{"id": nest_id, "pos": Vector3(1, 0, 0), "facing_yaw": PI / 2.0, "occupant": NEST_SUPPORT_ID, "hp_frac": 1.0, "team": 0}]
	bot["view"] = {NEST_SUPPORT_ID: _es(0, Vector3.ZERO), 20: _es(1, Vector3(10, 0, 0))}   # enemy dead ahead (+x, in arc)
	bd._ex.drive_mounted_nest(bot, _es(0, Vector3.ZERO))
	var inputs := _sends_of(bot, Protocol.Msg.INPUT)
	assert_eq(inputs.size(), 1, "one input command sent while manning")
	var frame: Dictionary = (InputCommand.decode(inputs[0])["frames"] as Array)[0]
	assert_true(int(frame["buttons"]) & InputCommand.BTN_FIRE != 0, "holds fire on an enemy inside the arc")
	assert_almost_eq(float(frame["yaw"]), PI / 2.0, 0.02, "aims at the enemy (+x -> yaw PI/2)")

func test_mounted_gunner_holds_fire_on_enemy_behind_arc() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	var nest_id := Emplacement.id_for(0)
	bot["self_state"] = {"mounted_nest": nest_id}
	# Nest faces +x; enemy is directly BEHIND (-x), well outside the fire arc.
	bot["nests"] = [{"id": nest_id, "pos": Vector3.ZERO, "facing_yaw": PI / 2.0, "occupant": NEST_SUPPORT_ID, "hp_frac": 1.0, "team": 0}]
	bot["view"] = {NEST_SUPPORT_ID: _es(0, Vector3.ZERO), 20: _es(1, Vector3(-10, 0, 0))}
	bd._ex.drive_mounted_nest(bot, _es(0, Vector3.ZERO))
	var frame: Dictionary = (InputCommand.decode(_sends_of(bot, Protocol.Msg.INPUT)[0])["frames"] as Array)[0]
	assert_true(int(frame["buttons"]) & InputCommand.BTN_FIRE == 0, "does not waste the belt on a target behind the arc")

func test_mounted_holds_fire_only_within_real_arc() -> void:
	# A target ~60° off the nest facing is OUTSIDE the server's real 45° traverse clamp
	# (Emplacement.clamp_yaw pins the shot at the arc edge), so the bot must NOT open fire — the
	# 0°/180° tests above miss this 45–69° gap the fire-arc bug lived in.
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	var nest_id := Emplacement.id_for(0)
	bot["self_state"] = {"mounted_nest": nest_id}
	# Nest faces +Z (yaw 0); enemy 60° off +Z toward +x -> beyond the 45° arc.
	bot["nests"] = [{"id": nest_id, "pos": Vector3.ZERO, "facing_yaw": 0.0, "occupant": NEST_SUPPORT_ID, "hp_frac": 1.0, "team": 0}]
	var enemy_pos := Vector3(sin(deg_to_rad(60)), 0.0, cos(deg_to_rad(60))) * 10.0
	bot["view"] = {NEST_SUPPORT_ID: _es(0, Vector3.ZERO), 20: _es(1, enemy_pos)}
	bd._ex.drive_mounted_nest(bot, _es(0, Vector3.ZERO))
	var frame: Dictionary = (InputCommand.decode(_sends_of(bot, Protocol.Msg.INPUT)[0])["frames"] as Array)[0]
	assert_true(int(frame["buttons"]) & InputCommand.BTN_FIRE == 0, "60° off facing is outside the real 45° arc -> no fire")

func test_mounted_gunner_holds_fire_beyond_max_range() -> void:
	# G3c: an in-arc, level enemy that is far beyond the sane engage range must NOT draw fire — the MG
	# would just burn belt/heat at a speck it can't meaningfully hit.
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	var nest_id := Emplacement.id_for(0)
	bot["self_state"] = {"mounted_nest": nest_id}
	# Nest faces +x; enemy dead ahead (in arc, level) but 300 m out — past LMG_NEST_MAX_FIRE_RANGE.
	bot["nests"] = [{"id": nest_id, "pos": Vector3.ZERO, "facing_yaw": PI / 2.0, "occupant": NEST_SUPPORT_ID, "hp_frac": 1.0, "team": 0}]
	bot["view"] = {NEST_SUPPORT_ID: _es(0, Vector3.ZERO), 20: _es(1, Vector3(300, 0, 0))}
	bd._ex.drive_mounted_nest(bot, _es(0, Vector3.ZERO))
	var frame: Dictionary = (InputCommand.decode(_sends_of(bot, Protocol.Msg.INPUT)[0])["frames"] as Array)[0]
	assert_true(int(frame["buttons"]) & InputCommand.BTN_FIRE == 0, "beyond max range -> hold fire")

func test_mounted_gunner_holds_fire_above_pitch_band() -> void:
	# G3c (the sky-fire bug): an in-arc, in-range enemy that sits high above the muzzle needs a pitch
	# beyond the turret's up-clamp. Firing there pins the barrel at the clamp and the burst sails into the
	# SKY over the target, so the bot must HOLD FIRE rather than fire at the clamp.
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	var nest_id := Emplacement.id_for(0)
	bot["self_state"] = {"mounted_nest": nest_id}
	# Nest faces +x; enemy 5 m ahead but 10 m UP -> required pitch ~63° >> pitch_hi (25°).
	bot["nests"] = [{"id": nest_id, "pos": Vector3.ZERO, "facing_yaw": PI / 2.0, "occupant": NEST_SUPPORT_ID, "hp_frac": 1.0, "team": 0}]
	bot["view"] = {NEST_SUPPORT_ID: _es(0, Vector3.ZERO), 20: _es(1, Vector3(5, 10, 0))}
	bd._ex.drive_mounted_nest(bot, _es(0, Vector3.ZERO))
	var frame: Dictionary = (InputCommand.decode(_sends_of(bot, Protocol.Msg.INPUT)[0])["frames"] as Array)[0]
	assert_true(int(frame["buttons"]) & InputCommand.BTN_FIRE == 0, "target above the pitch band -> no sky-fire")

func test_mounted_gunner_fires_level_target_with_pitch_in_band() -> void:
	# G3c: an in-arc, in-range, roughly-level enemy DOES draw fire, and the aimed pitch sits INSIDE the
	# turret band (not pinned to the +25° up-clamp) — proves we aim at the body, not the sky.
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	var nest_id := Emplacement.id_for(0)
	bot["self_state"] = {"mounted_nest": nest_id}
	# Nest faces +x; enemy 30 m ahead, ~1 m below (a body, near-level) -> in arc, in range, pitch tiny.
	bot["nests"] = [{"id": nest_id, "pos": Vector3.ZERO, "facing_yaw": PI / 2.0, "occupant": NEST_SUPPORT_ID, "hp_frac": 1.0, "team": 0}]
	bot["view"] = {NEST_SUPPORT_ID: _es(0, Vector3.ZERO), 20: _es(1, Vector3(30, -1, 0))}
	bd._ex.drive_mounted_nest(bot, _es(0, Vector3.ZERO))
	var frame: Dictionary = (InputCommand.decode(_sends_of(bot, Protocol.Msg.INPUT)[0])["frames"] as Array)[0]
	assert_true(int(frame["buttons"]) & InputCommand.BTN_FIRE != 0, "level, in-arc, in-range enemy -> fire")
	var pitch := wrapf(float(frame["pitch"]), -PI, PI)   # wire angle is unsigned [0,TAU) -> signed
	assert_true(pitch >= -bd.LMG_NEST_PITCH_LO and pitch <= bd.LMG_NEST_PITCH_HI,
		"aimed pitch is inside the turret band, not pinned to the up-clamp")

func test_mounted_gunner_dismounts_after_no_target_window() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 0, 1000)
	var nest_id := Emplacement.id_for(0)
	bot["self_state"] = {"mounted_nest": nest_id}
	bot["view"] = {NEST_SUPPORT_ID: _es(0, Vector3.ZERO)}   # no enemies at all
	# First tick with no target arms the timer (no dismount yet).
	bd._ex.drive_mounted_nest(bot, _es(0, Vector3.ZERO))
	assert_eq(_sends_of(bot, Protocol.Msg.EMPLACEMENT_ACTION).size(), 0, "grace window: still seated")
	# A tick past the dismount window -> EA_DISMOUNT.
	bot["server_tick"] = 1000 + bd.LMG_NEST_DISMOUNT_NOTARGET_TICKS
	bd._ex.drive_mounted_nest(bot, _es(0, Vector3.ZERO))
	var dm := _sends_of(bot, Protocol.Msg.EMPLACEMENT_ACTION)
	assert_eq(dm.size(), 1, "dismounts once the fight is over")
	assert_eq(int(Protocol.decode_emplacement_action(dm[0])["action"]), Protocol.EA_DISMOUNT, "EA_DISMOUNT")

# --- end-to-end vs the REAL server (EmplacementHarness) ----------------------

func test_deploy_packet_is_accepted_by_the_real_server() -> void:
	# The exerciser's deploy packet must satisfy ServerEmplacement.deploy end-to-end (not just look
	# plausible) — feed the captured pos/dir into the production server path and prove a nest appears.
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 1, 1000)   # harness support pawn is team 1
	bd._ex.maybe_lmg_nest(bot, _es(1, Vector3.ZERO), _es(0, Vector3(10, 0, 0)))
	var d := Protocol.decode_gadget_action(_sends_of(bot, Protocol.Msg.GADGET_ACTION)[0])

	var h := EmplacementHarness.new()
	h.add_support(Vector3.ZERO, 1)   # registers pawn 7 (== NEST_SUPPORT_ID) with the LMG-nest loadout
	assert_eq(h.nest_count(), 0, "precondition: no nests")
	h.deploy(d["pos"], d["dir"])
	assert_eq(h.nest_count(), 1, "the bot's deploy request produced a live nest server-side")
	assert_eq(h.first_nest().team, 1, "nest carries the deploying support bot's team")

func test_deploy_then_mount_end_to_end() -> void:
	# Full hand-off: deploy through the real server, mirror the resulting EMPLACEMENT_LIST back into the
	# bot, and prove maybe_lmg_nest then mounts it (server binds the seat -> pawn.mounted_nest set).
	var h := EmplacementHarness.new()
	var sp := h.add_support(Vector3.ZERO, 1)
	h.deploy(Vector3(2, 0, 0), Vector3(1, 0, 0))   # nest ahead; seat lands ~1.4 m away
	assert_eq(h.nest_count(), 1, "nest deployed")

	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(NEST_SUPPORT_ID, 1, 2000)
	bot["nests"] = h.emp.build_list()   # exactly what EMPLACEMENT_LIST would carry to the client
	# Bot is at the seat position, unmounted -> maybe_lmg_nest should request the seat.
	var seat: Vector3 = h.first_nest().seat_world()
	bd._ex.maybe_lmg_nest(bot, _es(1, seat), _es(0, Vector3(10, 0, 0)))
	var mounts := _sends_of(bot, Protocol.Msg.EMPLACEMENT_ACTION)
	assert_eq(mounts.size(), 1, "mount requested for the in-reach nest")
	var nest_id := int(Protocol.decode_emplacement_action(mounts[0])["nest_id"])

	h.mount(nest_id)   # server applies the mount
	assert_true(sp.mounted_nest != 0, "the support pawn ends up manning the nest")
	assert_eq(h.first_nest().occupant, NEST_SUPPORT_ID, "the nest's seat is bound to the bot")

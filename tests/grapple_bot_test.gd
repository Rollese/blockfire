extends TestCase
## M19 P6 Task 11: ASSAULT grapple bot exerciser (bots/exercisers.gd maybe_grapple). Proves the fleet
## gate physically exercises the grapple's two paths: DEPLOY (fire the hook to drop a climbable rope near
## a target) and CUT (sever a server-armed enemy rope the bot is standing at). The rope/climb/cut
## mechanic itself is already proven by the grapple sim/server tests; this only proves the AI actually
## emits GA_GRAPPLE_FIRE / CUT_LADDER when it tactically makes sense (and stays quiet otherwise), so the
## 128-bot gate reports non-zero grapples_deployed / grapple_cuts instead of the gadget sitting unused.
##
## No sockets: the bot sends through a recording SpyNet; the decision logic is driven directly.

const BotExercisers := preload("res://bots/exercisers.gd")
const ServerFixture := preload("res://tests/server_fixture.gd")
const Protocol := preload("res://shared/net/protocol.gd")

# An Assault bot id whose deterministic loadout rolls GADGET_GRAPPLE: the ASSAULT gadget branch is
# [C4, BREACH, GRAPPLE][id % 3], so id % 3 == 2 -> GRAPPLE. id 2 satisfies it directly.
const GRAPPLE_ASSAULT_ID := 2
# id % 3 == 0 -> GADGET_C4, a non-grapple Assault bot for the negative self-gate test.
const C4_ASSAULT_ID := 0

func _es(team: int, pos: Vector3, alive := true, downed := false) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = alive; e.is_downed = downed
	return e

## A bot dict wired to a recording SpyNet, minimally populated for the grapple exerciser paths.
## `charges` seeds the SELF_STATE mirror the same way the real bot reads grapple_charges from it.
func _make_bot(id: int, cls: int, server_tick: int, charges := 1) -> Dictionary:
	var net := ServerFixture.SpyNet.new()
	autofree(net)
	return {
		"net": net, "peer": null, "id": id, "class": cls, "team": 0,
		"server_tick": server_tick, "tick": server_tick, "last_seq": 0,
		"yaw": 0.0, "pitch": 0.0,
		"view": {}, "deployed_ladders": [], "self_state": {"grapple_charges": charges},
		"grapple_deploy_last_tick": -100000,
	}

func _sends_of(bot: Dictionary, msg: int) -> Array:
	return (bot["net"] as ServerFixture.SpyNet).bytes_of(msg)

# --- preconditions + pure helper --------------------------------------------

func test_gadget_id_precondition() -> void:
	assert_eq(Loadout.bot_gadget(GRAPPLE_ASSAULT_ID, Loadout.ASSAULT), Loadout.GADGET_GRAPPLE,
		"id 2 Assault rolls the grappling hook — the exerciser's self-gate")
	assert_eq(Loadout.bot_gadget(C4_ASSAULT_ID, Loadout.ASSAULT), Loadout.GADGET_C4,
		"id 0 Assault rolls C4 — used below as the non-grapple control")

func test_a_grapple_assault_bot_id_exists() -> void:
	var gid := -1
	for id in range(0, 60):
		if Loadout.bot_gadget(id, Loadout.ASSAULT) == Loadout.GADGET_GRAPPLE:
			gid = id; break
	assert_true(gid >= 0, "at least one Assault bot id rolls the grapple (so the fleet exercises it)")

func test_nearest_cuttable_ladder_picks_in_range_armed_rope() -> void:
	var ladders := [{"id": 7, "x": 1.0, "z": 0.0, "bottom_y": 0.0, "top_y": 4.0, "cuttable": true}]
	assert_eq(BotExercisers.nearest_cuttable_ladder(ladders, Vector3.ZERO, Grapple.CUT_RADIUS), 7,
		"a cuttable rope 1 m away is within CUT_RADIUS")

func test_nearest_cuttable_ladder_skips_uncut_and_far() -> void:
	var not_armed := {"id": 1, "x": 0.5, "z": 0.0, "bottom_y": 0.0, "top_y": 4.0, "cuttable": false}
	var far := {"id": 2, "x": 20.0, "z": 0.0, "bottom_y": 0.0, "top_y": 4.0, "cuttable": true}
	assert_eq(BotExercisers.nearest_cuttable_ladder([not_armed, far], Vector3.ZERO, Grapple.CUT_RADIUS), 0,
		"a not-yet-armed rope and an out-of-radius rope are both rejected")

# --- maybe_grapple: self-gate / deploy / cut --------------------------------

func test_non_grapple_gadget_bot_does_nothing() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(C4_ASSAULT_ID, Loadout.ASSAULT, 1000)   # id 0 -> C4, not the grapple
	bd._ex.maybe_grapple(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	assert_eq((bot["net"] as ServerFixture.SpyNet).sends.size(), 0, "self-gate: no grapple packets from a non-grapple bot")

func test_deploy_fired_when_charged_with_a_target() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(GRAPPLE_ASSAULT_ID, Loadout.ASSAULT, 1000)
	var me := _es(0, Vector3.ZERO)
	bd._ex.maybe_grapple(bot, me, _es(1, Vector3(10, 0, 0)))
	var fires := _sends_of(bot, Protocol.Msg.GADGET_ACTION)
	assert_eq(fires.size(), 1, "one grapple-fire request sent")
	var g := Protocol.decode_gadget_action(fires[0])
	assert_eq(int(g["action"]), Protocol.GA_GRAPPLE_FIRE, "it's a GA_GRAPPLE_FIRE")
	# Aim is a real world-space vector toward the enemy (+x), tilted UP so the march tends to strike a
	# wall/ledge rather than the ground — NOT a yaw-derived direction.
	var aim: Vector3 = g["dir"]
	assert_true(aim.x > 0.0, "aims toward the enemy along +x")
	assert_true(aim.y > 0.0, "tilts up so the hook tends to catch a ledge, not the floor")
	assert_eq(int(bot["grapple_deploy_last_tick"]), 1000, "stamps the deploy cadence tick")

func test_no_deploy_without_a_charge() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(GRAPPLE_ASSAULT_ID, Loadout.ASSAULT, 1000, 0)   # 0 charges
	bd._ex.maybe_grapple(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	assert_eq((bot["net"] as ServerFixture.SpyNet).sends.size(), 0, "spent grapple -> no fire")

func test_no_deploy_without_a_target() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(GRAPPLE_ASSAULT_ID, Loadout.ASSAULT, 1000)
	bd._ex.maybe_grapple(bot, _es(0, Vector3.ZERO), null)
	assert_eq((bot["net"] as ServerFixture.SpyNet).sends.size(), 0, "no target ahead -> no fire")

func test_deploy_suppressed_by_cadence() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(GRAPPLE_ASSAULT_ID, Loadout.ASSAULT, 1000)
	bot["grapple_deploy_last_tick"] = 1000 - (bd.GRAPPLE_DEPLOY_COOLDOWN_TICKS - 1)   # still cooling down
	bd._ex.maybe_grapple(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	assert_eq(_sends_of(bot, Protocol.Msg.GADGET_ACTION).size(), 0, "cadence gate blocks a second deploy")

func test_cut_sent_when_standing_at_an_armed_enemy_rope() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(GRAPPLE_ASSAULT_ID, Loadout.ASSAULT, 1000)
	# A cuttable rope within CUT_RADIUS of the bot -> cut it, and this takes priority over deploying.
	bot["deployed_ladders"] = [{"id": 42, "x": 0.5, "z": 0.0, "bottom_y": 0.0, "top_y": 4.0, "cuttable": true}]
	bd._ex.maybe_grapple(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	var cuts := _sends_of(bot, Protocol.Msg.CUT_LADDER)
	assert_eq(cuts.size(), 1, "one cut request")
	assert_eq(int(Protocol.decode_cut_ladder(cuts[0])["ladder_id"]), 42, "cuts the in-radius armed rope")
	assert_eq(_sends_of(bot, Protocol.Msg.GADGET_ACTION).size(), 0, "cut takes priority — no deploy this tick")

func test_no_cut_when_rope_not_yet_armed() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _make_bot(GRAPPLE_ASSAULT_ID, Loadout.ASSAULT, 1000, 0)   # 0 charges so it can't deploy either
	bot["deployed_ladders"] = [{"id": 42, "x": 0.5, "z": 0.0, "bottom_y": 0.0, "top_y": 4.0, "cuttable": false}]
	bd._ex.maybe_grapple(bot, _es(0, Vector3.ZERO), _es(1, Vector3(10, 0, 0)))
	assert_eq(_sends_of(bot, Protocol.Msg.CUT_LADDER).size(), 0, "a not-yet-armed rope is left alone")

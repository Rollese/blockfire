extends TestCase
## M19 P5 Task 7: SUPPORT riot-shield bot exerciser (bots/exercisers.gd maybe_riot_shield). Proves
## the pure gating deterministically — the real block/break mechanic itself is already proven by
## tests/riot_shield_server_test.gd; this only proves the fleet's AI actually raises BTN_SHIELD when
## it tactically makes sense (and stays down otherwise), so the 128-bot gate reports non-zero
## shield_blocks/shield_breaks instead of the gadget sitting unexercised.

const BotExercisers := preload("res://bots/exercisers.gd")

# A Support bot id whose deterministic loadout rolls GADGET_RIOT_SHIELD: id % 3 == 2 (see
# Loadout.bot_gadget's SUPPORT branch). id 2 satisfies it directly.
const SHIELD_SUPPORT_ID := 2
# id % 3 == 0 -> GADGET_AMMO, a non-shield Support bot for the negative gate test.
const AMMO_SUPPORT_ID := 0

func _es(team: int, pos: Vector3) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = true; e.is_downed = false
	return e

func _bot(id: int, cls: int, yaw: float) -> Dictionary:
	return {"id": id, "class": cls, "yaw": yaw}

func test_gadget_id_precondition() -> void:
	assert_eq(Loadout.bot_gadget(SHIELD_SUPPORT_ID, Loadout.SUPPORT), Loadout.GADGET_RIOT_SHIELD,
		"id 2 Support rolls the riot shield — the exerciser's self-gate")
	assert_eq(Loadout.bot_gadget(AMMO_SUPPORT_ID, Loadout.SUPPORT), Loadout.GADGET_AMMO,
		"id 0 Support rolls ammo — used below as the non-shield control")

func test_raises_shield_and_faces_enemy_ahead_in_range() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _bot(SHIELD_SUPPORT_ID, Loadout.SUPPORT, 0.0)   # facing +z
	var me := _es(0, Vector3.ZERO)
	# Enemy mostly ahead (+z) with a slight lateral offset, well inside engage range and the front arc.
	var target := _es(1, Vector3(2, 0, 10))
	var got := bd._ex.maybe_riot_shield(bot, me, target)
	assert_eq(got, InputCommand.BTN_SHIELD, "enemy ahead + in range -> raises the shield")
	assert_almost_eq(float(bot["yaw"]), atan2(2.0, 10.0), 0.001, "squares facing exactly at the enemy")

func test_no_target_does_not_raise() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _bot(SHIELD_SUPPORT_ID, Loadout.SUPPORT, 0.0)
	var me := _es(0, Vector3.ZERO)
	assert_eq(bd._ex.maybe_riot_shield(bot, me, null), 0, "no enemy -> no shield")

func test_target_beyond_engage_range_does_not_raise() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _bot(SHIELD_SUPPORT_ID, Loadout.SUPPORT, 0.0)
	var me := _es(0, Vector3.ZERO)
	var target := _es(1, Vector3(0, 0, bd.RIOT_SHIELD_ENGAGE_RANGE + 5.0))   # dead ahead but too far
	assert_eq(bd._ex.maybe_riot_shield(bot, me, target), 0, "enemy beyond engage range -> no shield")
	assert_almost_eq(float(bot["yaw"]), 0.0, 0.001, "facing untouched when the shield doesn't raise")

func test_target_behind_current_facing_does_not_raise() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _bot(SHIELD_SUPPORT_ID, Loadout.SUPPORT, 0.0)   # facing +z
	var me := _es(0, Vector3.ZERO)
	var target := _es(1, Vector3(0, 0, -10))   # directly behind
	assert_eq(bd._ex.maybe_riot_shield(bot, me, target), 0,
		"enemy behind current facing -> no shield (never spins around to turtle)")
	assert_almost_eq(float(bot["yaw"]), 0.0, 0.001, "facing untouched when the shield doesn't raise")

func test_non_shield_gadget_bot_does_nothing() -> void:
	var bd := BotDriver.new(); autofree(bd)
	var bot := _bot(AMMO_SUPPORT_ID, Loadout.SUPPORT, 0.0)   # id 0 -> AMMO, not the riot shield
	var me := _es(0, Vector3.ZERO)
	var target := _es(1, Vector3(0, 0, 10))   # would otherwise qualify
	assert_eq(bd._ex.maybe_riot_shield(bot, me, target), 0, "self-gate: non-shield bot never raises")

func test_non_support_class_does_nothing() -> void:
	var bd := BotDriver.new(); autofree(bd)
	# id 2 rolls RIOT_SHIELD only for SUPPORT; force a different class so bot_gadget takes another path.
	var bot := _bot(SHIELD_SUPPORT_ID, Loadout.ASSAULT, 0.0)
	var me := _es(0, Vector3.ZERO)
	var target := _es(1, Vector3(0, 0, 10))
	assert_eq(bd._ex.maybe_riot_shield(bot, me, target), 0, "self-gate: wrong class never raises")

extends TestCase
## Medic/Support give-target selection (bot_driver.give_pick). Regression for the
## give hijack: a medic used to aim-lock onto ANY alive mate within 3 m (even at
## full HP) every tick, overriding combat aim and spamming GIVE_START.

const BotDriver := preload("res://bots/bot_driver.gd")

func _es(team: int, pos: Vector3, hp := 100, alive := true, downed := false) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.health = hp; e.alive = alive; e.is_downed = downed
	return e

func test_full_hp_mate_not_picked() -> void:
	var view := {1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(1, 0, 0), 100)}
	assert_eq(BotDriver.give_pick(view, 1, 0, Vector3.ZERO), 0, "no give to a full-HP mate")

func test_hurt_mate_in_range_picked() -> void:
	var view := {1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(1, 0, 0), 60)}
	assert_eq(BotDriver.give_pick(view, 1, 0, Vector3.ZERO), 2, "hurt mate within range is picked")

func test_hurt_enemy_ignored() -> void:
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(1, 0, 0), 30)}
	assert_eq(BotDriver.give_pick(view, 1, 0, Vector3.ZERO), 0, "enemies are never give targets")

func test_downed_and_dead_mates_ignored() -> void:
	var view := {
		1: _es(0, Vector3.ZERO),
		2: _es(0, Vector3(1, 0, 0), 20, true, true),
		3: _es(0, Vector3(2, 0, 0), 20, false),
	}
	assert_eq(BotDriver.give_pick(view, 1, 0, Vector3.ZERO), 0, "downed (revive path) and dead mates skipped")

func test_out_of_range_hurt_mate_ignored() -> void:
	var view := {1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(5, 0, 0), 40)}
	assert_eq(BotDriver.give_pick(view, 1, 0, Vector3.ZERO), 0, "beyond give range")

func test_nearest_hurt_mate_wins() -> void:
	var view := {
		1: _es(0, Vector3.ZERO),
		2: _es(0, Vector3(2, 0, 0), 40),
		3: _es(0, Vector3(1, 0, 0), 70),
	}
	assert_eq(BotDriver.give_pick(view, 1, 0, Vector3.ZERO), 3, "nearest hurt mate preferred")

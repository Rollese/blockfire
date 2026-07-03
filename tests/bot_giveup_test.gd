extends TestCase
## Downed bots give up when no friendly is near enough to revive (2026-07-03) — clears isolated
## bodies fast instead of waiting out the whole bleedout.
const Bot := preload("res://bots/bot_driver.gd")

func _es(team: int, pos: Vector3, alive := true, downed := false) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = alive; e.is_downed = downed
	return e

func test_reviver_near_true_when_friendly_within_radius() -> void:
	var view := {1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(10, 0, 0))}
	assert_true(Bot._reviver_near(view, 1, 0, Vector3.ZERO), "alive friendly at 10 m -> wait for revive")

func test_reviver_near_false_for_far_enemy_downed_or_dead() -> void:
	var view := {
		1: _es(0, Vector3.ZERO),                      # self (ignored)
		2: _es(0, Vector3(30, 0, 0)),                 # friendly but 30 m (> 20)
		3: _es(1, Vector3(4, 0, 0)),                  # enemy close (not a reviver)
		4: _es(0, Vector3(3, 0, 0), true, true),      # friendly close but DOWNED (can't revive)
		5: _es(0, Vector3(3, 0, 0), false, false),    # friendly close but DEAD
	}
	assert_false(Bot._reviver_near(view, 1, 0, Vector3.ZERO), "no alive, up friendly within 20 m -> give up")

func test_reviver_near_ignores_self() -> void:
	assert_false(Bot._reviver_near({1: _es(0, Vector3.ZERO)}, 1, 0, Vector3.ZERO),
		"the downed bot itself is not a reviver")

func test_reviver_near_respects_radius_boundary() -> void:
	# 20 m exactly is within; just past is not.
	assert_true(Bot._reviver_near({1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(20, 0, 0))}, 1, 0, Vector3.ZERO))
	assert_false(Bot._reviver_near({1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(20.5, 0, 0))}, 1, 0, Vector3.ZERO))

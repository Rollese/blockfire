extends TestCase

# Mirrors server ledger accrual: each applied hit adds to ledger[attacker]; DeathRecap orders it.
func _accrue(ledger: Dictionary, attacker_id: int, dmg: int) -> void:
	ledger[attacker_id] = int(ledger.get(attacker_id, 0)) + dmg

# Mirrors the bleed-out/give-up killer attribution: credit whoever DOWNED the pawn (stored as
# downed_by), not the victim themselves. Falls back to self only when no attacker was recorded.
func _bleedout_killer(c: Dictionary, self_id: int) -> int:
	return int(c.get("downed_by", self_id))

func test_bleedout_credits_the_downer_not_self() -> void:
	assert_eq(_bleedout_killer({"downed_by": 9}, 7), 9, "bleed-out credits the attacker who downed you")
	assert_eq(_bleedout_killer({}, 7), 7, "falls back to self only when no downer recorded (e.g. fall)")

func test_ledger_accrues_then_sorts_for_recap() -> void:
	var ledger := {}
	_accrue(ledger, 7, 50)
	_accrue(ledger, 9, 20)
	_accrue(ledger, 7, 30)   # killer landed 80 total
	var attackers := DeathRecap.attackers_sorted(ledger)
	assert_eq(attackers[0]["id"], 7)
	assert_eq(attackers[0]["dmg"], 80)
	assert_eq(attackers[1]["id"], 9)

func test_distance_is_killer_to_victim() -> void:
	# DEATH_INFO distance is the straight-line range at the killing blow.
	var d := Vector3(0, 0, 0).distance_to(Vector3(30, 0, 40))
	assert_almost_eq(d, 50.0, 0.01)

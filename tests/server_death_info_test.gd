extends TestCase

# Mirrors server ledger accrual: each applied hit adds to ledger[attacker]; DeathRecap orders it.
func _accrue(ledger: Dictionary, attacker_id: int, dmg: int) -> void:
	ledger[attacker_id] = int(ledger.get(attacker_id, 0)) + dmg

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

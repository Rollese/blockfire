extends TestCase

func test_sorts_by_damage_desc_then_id() -> void:
	var ledger := {7: 20, 9: 80, 3: 80}
	var out := DeathRecap.attackers_sorted(ledger)
	assert_eq(out.size(), 3)
	assert_eq(out[0]["id"], 3, "ties broken by lower id first")
	assert_eq(out[0]["dmg"], 80)
	assert_eq(out[1]["id"], 9)
	assert_eq(out[2]["id"], 7)

func test_empty_ledger_is_empty_list() -> void:
	assert_eq(DeathRecap.attackers_sorted({}).size(), 0)

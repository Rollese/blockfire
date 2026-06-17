class_name DeathRecap
extends Object
## Pure: turn a per-life damage ledger {attacker_id -> total_dmg} into the ordered attacker list
## carried by DEATH_INFO (damage desc, then id asc for determinism). Presentation-only — no rules.

static func attackers_sorted(ledger: Dictionary) -> Array:
	var rows: Array = []
	for id in ledger:
		rows.append({"id": int(id), "dmg": int(ledger[id])})
	rows.sort_custom(func(a, b):
		if a["dmg"] != b["dmg"]:
			return a["dmg"] > b["dmg"]
		return a["id"] < b["id"])
	return rows

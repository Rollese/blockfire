extends TestCase
## Damage-ledger accrual + bleed-out attribution through the REAL server paths (was a local
## mirror — batch 5.2). The DEATH_INFO packet the victim receives is decoded off the SpyNet.

const F := preload("res://tests/server_fixture.gd")


func test_ledger_accrues_and_recap_sorts_by_damage() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	var victim := F.add_pawn(srv, 1)
	F.add_pawn(srv, 7, 1)
	F.add_pawn(srv, 9, 1)
	srv._apply_pawn_damage(1, victim, 50, false, Revive.Source.BULLET, 7, Weapon.AR)
	srv._apply_pawn_damage(1, victim, 20, false, Revive.Source.BULLET, 9, Weapon.SMG)
	srv._apply_pawn_damage(1, victim, 30, false, Revive.Source.BULLET, 7, Weapon.AR)   # lethal: 7 landed 80 total
	assert_true(victim.is_downed, "body damage to zero downs")
	var led: Dictionary = srv._clients[1]["dmg_ledger"]
	assert_eq(int(led[7]), 80, "ledger accrued per attacker")
	assert_eq(int(led[9]), 20)
	var attackers := DeathRecap.attackers_sorted(led)
	assert_eq(int(attackers[0]["id"]), 7, "recap sorted by damage dealt")
	assert_eq(int(attackers[0]["dmg"]), 80)
	assert_eq(int(attackers[1]["id"]), 9)


func test_bleedout_credits_the_downer_not_self() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	F.add_client(srv, 9, 1)
	var victim := F.add_pawn(srv, 1)
	var downer := F.add_pawn(srv, 9, 1)
	downer.pos = Vector3(30, 0, 40)   # range at down time = 50 m
	victim.health = 10
	srv._apply_pawn_damage(1, victim, 40, false, Revive.Source.BULLET, 9, Weapon.SMG)
	assert_true(victim.is_downed)
	victim.bleed_health = victim.bleed_floor + Revive.BLEED_RATE   # one step from bleeding out
	srv._support.step_downed()
	assert_false(victim.alive, "bled out")
	assert_eq(srv._clients[9]["kills"], 1, "bleed-out credits the attacker who downed you")
	assert_eq(srv._clients[1]["deaths"], 1)
	# The victim's DEATH_INFO packet names the downer + the range captured at down time.
	var infos: Array = (srv._net as F.SpyNet).bytes_of(Protocol.Msg.DEATH_INFO)
	assert_eq(infos.size(), 1, "victim got exactly one DEATH_INFO")
	var d := Protocol.decode_death_info(infos[0])
	assert_eq(int(d["killer"]), 9)
	assert_almost_eq(float(d["distance"]), 50.0, 0.11, "distance snapshotted at DOWN time (0.1 m wire quantization)")


func test_fall_bleedout_falls_back_to_self() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	var victim := F.add_pawn(srv, 1)
	victim.health = 5
	srv._apply_pawn_damage(1, victim, 40, false, Revive.Source.BULLET, 0, 0)   # no attacker (killer_id 0)
	assert_true(victim.is_downed)
	victim.bleed_health = victim.bleed_floor
	srv._support.step_downed()
	assert_false(victim.alive)
	assert_eq(srv._clients[1]["deaths"], 1)
	assert_eq(srv._clients[1]["kills"], 0, "self-attributed bleed-out is never a credit")

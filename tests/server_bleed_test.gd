extends TestCase
## M16 standing-bleed + bandage through the REAL server paths (no local mirrors): trigger on a
## below-threshold hit, drain to a down, bandage stops+heals+spends the victim-first pouch, a
## mid-channel hit resets progress, and revive-costs-a-bandage fails when both pouches are empty.

const F := preload("res://tests/server_fixture.gd")


func _apply(srv, victim: Pawn, dmg: int, source := Revive.Source.BULLET, killer_id := 0) -> void:
	srv._apply_pawn_damage(victim.id, victim, dmg, false, source, killer_id, Weapon.AR)


func test_below_threshold_bullet_starts_a_bleed() -> void:
	var srv = autofree(F.make_server())
	var c := F.add_client(srv, 1)
	var p := F.add_pawn(srv, 1)
	p.health = 100
	_apply(srv, p, 50, Revive.Source.BULLET, 2)   # 100 -> 50, below BLEED_THRESHOLD (60)
	assert_true(p.bleeding, "a hit that leaves you below 60 HP starts a bleed")
	assert_eq(p.bleed_by, 2, "credits the attacker")
	assert_eq(srv._stats.bleeds_started, 1)
	assert_true(c.has("dmg_ledger"))


func test_graze_above_threshold_does_not_bleed() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	var p := F.add_pawn(srv, 1)
	p.health = 100
	_apply(srv, p, 30, Revive.Source.BULLET, 2)   # 100 -> 70, still healthy
	assert_false(p.bleeding)
	assert_eq(srv._stats.bleeds_started, 0)


func test_bleed_drains_health_and_downs() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	var p := F.add_pawn(srv, 1)
	p.health = 100
	_apply(srv, p, 45, Revive.Source.BULLET, 2)   # 100 -> 55, bleeding
	assert_true(p.bleeding)
	srv._sim.tick = 0   # 0 % BLEED_RATE_TICKS == 0 -> every step_bleed drains 1
	for _i in 60:
		srv._support.step_bleed()
	assert_true(p.is_downed, "an ignored standing bleed drains to a down")
	assert_eq(p.down_count, 1, "the bleed-out down feeds the halving window")
	assert_false(p.bleeding, "going down clears the standing bleed")
	assert_true(srv._stats.bleed_downs >= 1)


func test_bandage_stops_bleed_and_heals_and_spends_pouch() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)   # healer (teammate)
	F.add_client(srv, 2)
	var healer := F.add_pawn(srv, 1)
	var patient := F.add_pawn(srv, 2)
	patient.pos = Vector3(1.0, 0.0, 0.0)   # within BANDAGE_RANGE
	patient.health = 40
	patient.bleeding = true
	var before := patient.bandage_count
	srv._support.set_bandaging(1, 2)
	srv._sim.tick = 1   # not a drain tick, so step_bleed does not interfere
	for _i in Bandage.channel_ticks(false):
		srv._support.step_bandage()
	assert_false(patient.bleeding, "a completed channel stops the bleed")
	assert_eq(patient.health, 40 + Bandage.BANDAGE_HEAL, "and heals")
	assert_eq(patient.bandage_count, before - 1, "victim-first pouch pays")
	assert_eq(srv._stats.bandages, 1)


func test_self_bandage_completes() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	var p := F.add_pawn(srv, 1)
	p.health = 30
	p.bleeding = true
	srv._support.set_bandaging(1, 1)   # target == self
	for _i in Bandage.channel_ticks(false):
		srv._support.step_bandage()
	assert_false(p.bleeding, "self-bandage stops your own bleed")
	assert_eq(p.health, 30 + Bandage.BANDAGE_HEAL)


func test_damage_mid_channel_resets_progress() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	F.add_client(srv, 2)
	F.add_pawn(srv, 1)
	var patient := F.add_pawn(srv, 2)
	patient.pos = Vector3(1.0, 0.0, 0.0)
	patient.health = 40
	patient.bleeding = true
	srv._support.set_bandaging(1, 2)
	for _i in 10:
		srv._support.step_bandage()
	assert_true(srv._support.bandage_ticks.has(2), "progress accrued")
	# Patient takes a hit mid-channel -> the channel hard-cancels (via _apply_pawn_damage).
	_apply(srv, patient, 5, Revive.Source.BULLET, 3)
	assert_false(srv._support.bandaging.has(1), "the latch is dropped")
	assert_false(srv._support.bandage_ticks.has(2), "progress is reset to zero")


func test_bandage_needs_a_charge() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	F.add_client(srv, 2)
	var healer := F.add_pawn(srv, 1)
	var patient := F.add_pawn(srv, 2)
	patient.pos = Vector3(1.0, 0.0, 0.0)
	patient.health = 40
	patient.bleeding = true
	healer.bandage_count = 0
	patient.bandage_count = 0
	srv._support.set_bandaging(1, 2)
	for _i in Bandage.channel_ticks(false) + 5:
		srv._support.step_bandage()
	assert_true(patient.bleeding, "no pouch -> the bandage never completes")
	assert_eq(srv._stats.bandages, 0)


func test_revive_fails_when_both_pouches_empty() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	F.add_client(srv, 2)
	var reviver := F.add_pawn(srv, 1)
	var downed := F.add_pawn(srv, 2)
	downed.is_downed = true
	downed.health = 0
	downed.bleed_health = -20
	downed.pos = Vector3(1.0, 0.0, 0.0)
	reviver.bandage_count = 0
	downed.bandage_count = 0
	srv._support.reviving[1] = 2
	for _i in Revive.REVIVE_TICKS + 5:
		srv._support.step_revives()
	assert_true(downed.is_downed, "a dry revive can never complete")
	assert_eq(srv._stats.revives, 0)


func test_revive_spends_a_bandage() -> void:
	var srv = autofree(F.make_server())
	F.add_client(srv, 1)
	F.add_client(srv, 2)
	var reviver := F.add_pawn(srv, 1)
	var downed := F.add_pawn(srv, 2)
	downed.is_downed = true
	downed.health = 0
	downed.bleed_health = -20
	downed.pos = Vector3(1.0, 0.0, 0.0)
	var before := downed.bandage_count
	srv._support.reviving[1] = 2
	for _i in Revive.REVIVE_TICKS:
		srv._support.step_revives()
	assert_false(downed.is_downed, "revive completes while a charge exists")
	assert_eq(downed.bandage_count, before - 1, "victim-first pouch pays for the revive")

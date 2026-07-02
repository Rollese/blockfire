extends TestCase
## Down/bleed-out/revive rules through the REAL server code paths (batch 5.2 killed the local
## mirrors of _apply_pawn_damage/_step_revives/_destroy_vehicle that could silently drift).
## Default pawns are Armor.LIGHT (body_mult 1.0), so damage numbers land unscaled. The pure
## Revive helper tests further down were never mirrors — they test shared code directly.

const F := preload("res://tests/server_fixture.gd")


func _apply(srv, victim: Pawn, dmg: int, headshot: bool, source: int, killer_id := 0) -> void:
	srv._apply_pawn_damage(victim.id, victim, dmg, headshot, source, killer_id, Weapon.AR)


func test_body_shot_to_zero_downs_not_kills() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	p.health = 10
	_apply(srv, p, 40, false, Revive.Source.BULLET)
	assert_true(p.is_downed, "body lethal hit downs")
	assert_true(p.alive, "downed pawn is still alive")


func test_headshot_to_zero_kills_outright() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	p.health = 10
	_apply(srv, p, 40, true, Revive.Source.BULLET)
	assert_false(p.alive, "headshot bypasses DBNO")
	assert_false(p.is_downed)


func test_blast_to_zero_kills_outright() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	p.health = 10
	_apply(srv, p, 40, false, Revive.Source.BLAST)
	assert_false(p.alive)


func test_downed_is_immune_to_headshot() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	p.is_downed = true
	p.bleed_health = 0
	_apply(srv, p, 999, true, Revive.Source.BULLET)
	assert_true(p.alive, "downed pawn is immune — a headshot does not finish it")
	assert_true(p.is_downed, "stays downed")


func test_downed_is_immune_to_blast() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	p.is_downed = true
	p.bleed_health = 0
	_apply(srv, p, 999, false, Revive.Source.BLAST)
	assert_true(p.alive, "downed pawn is immune — a blast does not finish it")
	assert_true(p.is_downed, "stays downed")


func test_downed_is_immune_to_body_fire() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	p.is_downed = true
	p.bleed_health = Revive.BLEEDOUT_FLOOR + 5
	_apply(srv, p, 999, false, Revive.Source.BULLET)
	assert_true(p.alive, "downed pawn is immune — body fire does not accelerate bleed")
	assert_true(p.is_downed, "stays downed")
	assert_eq(p.bleed_health, Revive.BLEEDOUT_FLOOR + 5, "enemy fire leaves bleed_health untouched")


func test_non_lethal_body_shot_leaves_pawn_standing() -> void:
	var srv = autofree(F.make_server())
	var p := F.add_pawn(srv, 1)
	_apply(srv, p, 30, false, Revive.Source.BULLET)
	assert_true(p.alive)
	assert_false(p.is_downed)
	assert_eq(p.health, 70)


func test_downed_bleeds_out_after_enough_ticks() -> void:
	var bh := 0
	var ticks := 0
	while not Revive.is_bled_out(bh):
		bh = Revive.bleed_step(bh, false)
		ticks += 1
		assert_true(ticks < 1000, "must terminate")
	# bleed-out window = |BLEEDOUT_FLOOR| / BLEED_RATE ticks (must exceed REVIVE_TICKS so a
	# teammate can revive a fresh down before it bleeds out).
	assert_eq(ticks, -Revive.BLEEDOUT_FLOOR / Revive.BLEED_RATE)
	assert_true(ticks > Revive.REVIVE_TICKS, "bleed-out must outlast a revive hold")


func test_halted_pawn_never_bleeds_out() -> void:
	var bh := -10
	for _i in 100:
		bh = Revive.bleed_step(bh, true)
	assert_false(Revive.is_bled_out(bh), "self-bandaged pawn holds")


func test_revive_threshold_non_medic_is_revive_ticks() -> void:
	assert_eq(Revive.revive_ticks(false), Revive.REVIVE_TICKS)


func test_medic_revive_threshold_is_half() -> void:
	assert_eq(Revive.revive_ticks(true) * 2, Revive.revive_ticks(false))


## Drive the REAL latched-revive loop: REVIVE_ACTION latches _reviving[reviver]=target, then
## _step_revives accumulates and completes.
func _drive_revive(srv, reviver_id: int, target_id: int, ticks: int) -> void:
	srv._reviving[reviver_id] = target_id
	for _i in ticks:
		srv._step_revives()


func test_revive_completes_and_restores_after_threshold() -> void:
	var srv = autofree(F.make_server())
	F.add_pawn(srv, 1)                    # reviver (alive)
	var downed := F.add_pawn(srv, 2)
	downed.is_downed = true
	downed.health = 0
	downed.bleed_health = -20
	downed.pos = Vector3(1.0, 0.0, 0.0)   # within REVIVE_RANGE
	_drive_revive(srv, 1, 2, Revive.REVIVE_TICKS)
	assert_false(downed.is_downed, "completes after full hold")
	assert_eq(downed.health, Revive.REVIVE_HP)
	assert_eq(downed.bleed_health, 0)
	assert_eq(srv._stats.revives, 1, "revive telemetry counted")


func test_medic_revives_in_half_the_hold() -> void:
	var srv = autofree(F.make_server())
	F.add_pawn(srv, 1)
	F.add_client(srv, 1)["class"] = Loadout.MEDIC
	var downed := F.add_pawn(srv, 2)
	downed.is_downed = true
	downed.pos = Vector3(1.0, 0.0, 0.0)
	_drive_revive(srv, 1, 2, Revive.revive_ticks(true))
	assert_false(downed.is_downed, "medic completes at the halved threshold")


func test_revive_blocked_when_not_teammate() -> void:
	var srv = autofree(F.make_server())
	F.add_pawn(srv, 1, 1)                 # enemy reviver (team 1)
	var downed := F.add_pawn(srv, 2, 0)
	downed.is_downed = true
	downed.pos = Vector3(1.0, 0.0, 0.0)
	_drive_revive(srv, 1, 2, Revive.REVIVE_TICKS * 2)
	assert_true(downed.is_downed, "enemy cannot revive — stays downed")
	assert_false(srv._reviving.has(1), "impossible revive latch is dropped")


func test_revive_blocked_when_out_of_range() -> void:
	var srv = autofree(F.make_server())
	F.add_pawn(srv, 1)
	var downed := F.add_pawn(srv, 2)
	downed.is_downed = true
	downed.pos = Vector3(0.0, 0.0, Revive.REVIVE_RANGE + 1.0)
	_drive_revive(srv, 1, 2, Revive.REVIVE_TICKS * 2)
	assert_true(downed.is_downed, "out-of-range reviver makes no progress")
	assert_true(srv._reviving.has(1), "transient out-of-range HOLDS the latch (no progress, no drop)")


func test_destroy_vehicle_kills_standing_and_downed_occupants() -> void:
	var srv = autofree(F.make_server())
	var standing := F.add_pawn(srv, 1)
	var downed := F.add_pawn(srv, 2)
	downed.health = 0
	downed.is_downed = true
	downed.bleed_health = -10
	var v := Vehicle.new()
	v.id = Vehicle.ID_BASE + 1
	v.seats = [1, 2]
	srv._sim.world.spawn_vehicle(v)
	srv._destroy_vehicle(v.id, v, 0)
	assert_false(standing.alive, "standing occupant is killed on vehicle destruction")
	assert_false(downed.alive, "downed occupant is killed too — not left revivable")
	assert_false(downed.is_downed)
	assert_false(v.alive, "vehicle marked destroyed")

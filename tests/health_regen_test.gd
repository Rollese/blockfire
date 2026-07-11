extends TestCase

const _SF := preload("res://tests/server_fixture.gd")

func _spawned(cls: int, hp: int) -> Array:   # [srv, client, pawn]
	var srv = _SF.make_server()
	var c := _SF.add_client(srv, 1, 0, false)
	c["loadout"] = Loadout.default_loadout(cls)
	c["class"] = cls
	var p := _SF.add_pawn(srv, 1, 0, Vector3.ZERO)
	srv._apply_loadout_to_client(c, p)
	p.health = hp
	return [srv, c, p]

func _advance(srv, ticks: int) -> void:
	for i in ticks:
		srv._step_health_regen()
		srv._sim.tick += 1

func test_regen_blocked_during_delay() -> void:
	var s = _spawned(Loadout.SUPPORT, 40)
	var srv = s[0]; var c = s[1]; var p = s[2]
	c["regen_block_until"] = srv._sim.tick + 150
	_advance(srv, 100)
	assert_eq(p.health, 40, "no regen while recently in combat")

func test_regen_after_delay() -> void:
	var s = _spawned(Loadout.SUPPORT, 40)
	var srv = s[0]; var c = s[1]; var p = s[2]
	c["regen_block_until"] = 0
	_advance(srv, 60)    # 2s at 10 HP/s ≈ +20
	assert_true(p.health >= 55 and p.health <= 65, "≈+20 HP after 2s out of combat, got %d" % p.health)

func test_assault_regenerates_faster() -> void:
	var a = _spawned(Loadout.ASSAULT, 40); var sup = _spawned(Loadout.SUPPORT, 40)
	a[1]["regen_block_until"] = 0; sup[1]["regen_block_until"] = 0
	_advance(a[0], 60); _advance(sup[0], 60)
	assert_true(int(a[2].health) > int(sup[2].health), "Combat Vigor heals more in the same window")

func test_no_regen_at_full_health() -> void:
	var s = _spawned(Loadout.ASSAULT, 100)
	s[1]["regen_block_until"] = 0
	_advance(s[0], 60)
	assert_eq(int(s[2].health), 100, "never overheals")

func test_no_regen_when_dead_or_downed() -> void:
	var s = _spawned(Loadout.ASSAULT, 30)
	s[1]["regen_block_until"] = 0
	s[2].alive = false
	_advance(s[0], 60)
	assert_eq(int(s[2].health), 30, "dead pawns don't regen")
	s[2].alive = true; s[2].is_downed = true
	_advance(s[0], 60)
	assert_eq(int(s[2].health), 30, "downed pawns don't regen")

func test_no_regen_while_bleeding() -> void:
	var s = _spawned(Loadout.SUPPORT, 40)
	var srv = s[0]; var c = s[1]; var p = s[2]
	c["regen_block_until"] = 0
	p.bleeding = true
	_advance(srv, 60)
	assert_eq(int(p.health), 40, "a bleeding pawn does not regen (must bandage / bleed out)")
	# after bandaging, regen resumes
	p.bleeding = false
	_advance(srv, 60)
	assert_true(int(p.health) > 40, "regen resumes once the bleed is bandaged")

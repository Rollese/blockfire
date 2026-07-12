extends TestCase
## M19 P5 Task 4: Support Riot Shield server sim — frontal GUN small-arms absorb into the
## shield-HP pool, break-with-no-overflow, and respawn re-arm. Real server paths via
## server_fixture.gd (not mirrors); the shield_up flag is set directly here (the per-tick
## injection loop is exercised by the Task 7 gate drill, not this unit).

const F := preload("res://tests/server_fixture.gd")

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":0}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'


func setup() -> void:
	Weapon.reset_registry()
	assert_true(Weapon.load_from_file("res://data/weapons.json")["ok"], "weapons.json loads")


func teardown() -> void:
	Weapon.reset_registry()


## A ServerMain with the real gadget catalog + a map/conquest so the respawn spawn-select resolves.
func _srv() -> Node:
	var srv = autofree(F.make_server())
	srv._gadgets = Gadget.load_file("res://data/gadgets.json")
	assert_true(srv._gadgets != null, "gadgets.json loads")
	srv._map = MapDef.from_json_string(MAP_JSON)["map"]
	srv._conquest = ConquestState.new(srv._map)
	return srv


## Shield-Support victim at origin facing +Z (yaw 0), shield up + full pool seeded via the
## real loadout path. Returns the victim pawn.
func _shield_victim(srv, id: int) -> Pawn:
	var c := F.add_client(srv, id, 0, false)
	c["class"] = Loadout.SUPPORT
	c["loadout"]["class"] = Loadout.SUPPORT
	c["loadout"]["gadget"] = Loadout.GADGET_RIOT_SHIELD
	var p := F.add_pawn(srv, id, 0)
	srv._apply_loadout_to_client(c, p)   # seeds shield_hp full, shield_broken_until_tick 0
	p.pos = Vector3.ZERO
	p.yaw = 0.0
	p.health = 100
	p.shield_up = true
	return p


## Plain enemy attacker at `pos` on the other team.
func _attacker(srv, id: int, pos: Vector3) -> Pawn:
	F.add_client(srv, id, 1, false)
	var a := F.add_pawn(srv, id, 1)
	a.pos = pos
	return a


func test_frontal_bullet_absorbed() -> void:
	var srv := _srv()
	var v := _shield_victim(srv, 1)
	_attacker(srv, 2, Vector3(0, 0, 5))   # +Z, dead ahead of a yaw-0 bearer
	srv._apply_pawn_damage(1, v, 40, false, Revive.Source.BULLET, 2, 0)
	assert_eq(int(v.health), 100, "frontal gun bullet takes no health")
	assert_eq(int(v.shield_hp), RiotShield.SHIELD_HP - 40, "pool absorbed the hit")


func test_flank_bullet_hits_health() -> void:
	var srv := _srv()
	var v := _shield_victim(srv, 1)
	_attacker(srv, 2, Vector3(5, 0, 0))   # +X, 90 deg to the side (outside the 75 deg half-arc)
	srv._apply_pawn_damage(1, v, 40, false, Revive.Source.BULLET, 2, 0)
	assert_true(int(v.health) < 100, "flank bullet bypasses the shield and cuts health")
	assert_eq(int(v.shield_hp), RiotShield.SHIELD_HP, "pool untouched by a flank hit")


func test_frontal_explosive_bypasses() -> void:
	var srv := _srv()
	var v := _shield_victim(srv, 1)
	_attacker(srv, 2, Vector3(0, 0, 5))
	srv._apply_pawn_damage(1, v, 40, false, Revive.Source.BLAST, 2, 0)
	assert_true(int(v.health) < 100, "explosive bypasses a frontal shield")
	assert_eq(int(v.shield_hp), RiotShield.SHIELD_HP, "pool untouched by blast")


func test_frontal_melee_bypasses() -> void:
	var srv := _srv()
	var v := _shield_victim(srv, 1)
	_attacker(srv, 2, Vector3(0, 0, 5))
	# BULLET source but is_melee=true (melee reuses Source.BULLET) — must NOT be blocked.
	srv._apply_pawn_damage(1, v, 40, false, Revive.Source.BULLET, 2, 0, true)
	assert_true(int(v.health) < 100, "frontal melee bypasses the shield")
	assert_eq(int(v.shield_hp), RiotShield.SHIELD_HP, "pool untouched by melee")


func test_break_no_overflow() -> void:
	var srv := _srv()
	var v := _shield_victim(srv, 1)
	_attacker(srv, 2, Vector3(0, 0, 5))
	v.shield_hp = 30
	srv._apply_pawn_damage(1, v, 100, false, Revive.Source.BULLET, 2, 0)
	assert_eq(int(v.health), 100, "the breaking shot does NOT overflow into health")
	assert_eq(int(v.shield_hp), 0, "pool emptied on break")
	assert_false(v.shield_up, "shield forced down on break")
	assert_true(v.shield_broken_until_tick > srv._sim.tick, "break lockout armed into the future")


func test_respawn_rearms() -> void:
	var srv := _srv()
	var v := _shield_victim(srv, 1)
	srv._sim.tick = 10   # respawn gate is `respawn_tick > 0 and tick >= respawn_tick`
	v.shield_hp = 0
	v.shield_broken_until_tick = srv._sim.tick + 999999
	v.alive = false
	srv._clients[1]["respawn_tick"] = 5
	srv._handle_respawns()
	assert_eq(int(v.shield_hp), RiotShield.SHIELD_HP, "respawn re-arms the pool to full")
	assert_eq(int(v.shield_broken_until_tick), 0, "respawn clears the break lockout")

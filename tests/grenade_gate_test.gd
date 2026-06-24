extends TestCase
## M5.5-P3 deterministic gate: melee + throwables proven with NO bots/AI. A ServerMain built
## WITHOUT _ready() (no ENet); pawns/grenades placed by hand and stepped tick-by-tick. Per project
## policy mechanics are proven deterministically, not gated on emergent bot AI.

func _make_server() -> Node:
	var srv = preload("res://server/server_main.gd").new()
	srv._catalog = PieceCatalog.load_file("res://pieces/pieces.json")
	srv._store = StructureStore.new(srv._catalog)
	return srv

func _add_pawn(srv, id: int, pos: Vector3, team: int) -> Pawn:
	var p: Pawn = srv._sim.world.spawn(id)
	p.pos = pos
	p.team = team
	return p

func _rebuild_grid(srv) -> void:
	srv._grid.clear()
	srv._positions.clear()
	for id in srv._sim.world.pawns:
		var p: Pawn = srv._sim.world.pawns[id]
		srv._grid.insert(id, p.pos)
		srv._positions[id] = p.pos

func _idx(cat: PieceCatalog, id: String) -> int:
	for i in cat.size():
		if cat.name_of(i) == id: return i
	return -1

## Minimal client record sufficient for melee resolve + the kill path (_kill_pawn).
func _client(srv, id: int, cls: int, weapon: int) -> Dictionary:
	var c := {
		"weapon": weapon, "class": cls, "melee_ready_tick": 0,
		"peer": null, "dmg_ledger": {}, "auto_deploy": true,
		"deaths": 0, "kills": 0, "score": 0,
	}
	srv._clients[id] = c
	return c

## Wire the death machinery a melee/blast kill touches (sends become no-ops with null peers).
func _enable_kills(srv) -> void:
	srv._net = NetHost.new()
	srv._conquest = ConquestState.new()

## A wall cell in the grenade's flight path (cell (0,0,1) => world z in [2,4], x in [-1,1]).
func _place_wall(srv) -> void:
	var bwall := _idx(srv._catalog, "bwall")
	srv._store.place(1, bwall, Vector3i(0, 0, 1), 0, -1, 1)

# --- Task 2: impact-grenade contact detonation -------------------------------------------------

func test_impact_detonates_on_wall_contact() -> void:
	var srv := _make_server()
	_place_wall(srv)
	# Slight upward arc so it stays airborne until it reaches the wall (decouples from ground hit).
	var dir := Vector3(0.0, 0.4, 1.0).normalized()
	srv._grenades.append({
		"owner": 1, "team": 0, "type": Grenade.IMPACT,
		"pos": Vector3(0.0, 1.0, 0.0), "vel": Grenade.launch_velocity(dir),
		"detonate_tick": srv._sim.tick + 45,
	})
	var detonated := false
	for _i in 15:
		srv._step_grenades()
		if srv._nades >= 1:
			detonated = true
			break
	assert_true(detonated, "impact grenade detonated on structure contact")
	assert_eq(srv._grenades.size(), 0, "impact grenade consumed from the pool")
	srv.free()

func test_frag_ignores_wall_and_waits_for_fuse() -> void:
	var srv := _make_server()
	_place_wall(srv)
	var dir := Vector3(0.0, 0.4, 1.0).normalized()
	srv._grenades.append({
		"owner": 1, "team": 0, "type": Grenade.FRAG,
		"pos": Vector3(0.0, 1.0, 0.0), "vel": Grenade.launch_velocity(dir),
		"detonate_tick": srv._sim.tick + 45,
	})
	# Same 15-step window: frag must NOT structure-detonate (still airborne, fuse not elapsed).
	for _i in 15:
		srv._step_grenades()
	assert_eq(srv._nades, 0, "frag does not detonate on structure contact")
	assert_eq(srv._grenades.size(), 1, "frag still in flight (fuse not elapsed, airborne)")
	srv.free()

# --- Task 3: melee knife resolve --------------------------------------------------------------

func test_knife_frontal_does_body_damage_not_kill() -> void:
	var srv := _make_server()
	_client(srv, 1, Loadout.ASSAULT, Weapon.PISTOL)
	var atk := _add_pawn(srv, 1, Vector3.ZERO, 0); atk.yaw = 0.0          # faces +z
	var victim := _add_pawn(srv, 2, Vector3(0, 0, 1.0), 1); victim.yaw = PI  # faces attacker
	srv._resolve_melee(1)
	assert_true(victim.alive and not victim.is_downed, "frontal knife did not kill")
	assert_true(victim.health < 100, "frontal knife dealt body damage")
	srv.free()

func test_knife_backstab_instakills() -> void:
	var srv := _make_server()
	_enable_kills(srv)
	_client(srv, 1, Loadout.ASSAULT, Weapon.PISTOL)
	_client(srv, 2, Loadout.ASSAULT, Weapon.AR)
	var atk := _add_pawn(srv, 1, Vector3.ZERO, 0); atk.yaw = 0.0          # faces +z
	var victim := _add_pawn(srv, 2, Vector3(0, 0, 1.0), 1); victim.yaw = 0.0  # faces away (+z)
	srv._resolve_melee(1)
	assert_false(victim.alive, "rear-arc back-stab instant-killed (bypassed DBNO)")
	assert_false(victim.is_downed, "back-stab is a clean kill, not a down")
	assert_eq(srv._backstabs, 1, "back-stab telemetry incremented")
	srv.free()

func test_melee_cooldown_blocks_second_swing() -> void:
	var srv := _make_server()
	_client(srv, 1, Loadout.ASSAULT, Weapon.PISTOL)
	var atk := _add_pawn(srv, 1, Vector3.ZERO, 0); atk.yaw = 0.0
	var victim := _add_pawn(srv, 2, Vector3(0, 0, 1.0), 1); victim.yaw = PI
	srv._resolve_melee(1)
	var hp_after_first := victim.health
	srv._resolve_melee(1)   # same tick -> cooldown blocks
	assert_eq(victim.health, hp_after_first, "second swing blocked by cooldown")
	srv.free()

# --- Task 4: Engineer sledgehammer ------------------------------------------------------------

## A wall cell directly ahead of a pawn standing at z=-0.5 facing +z (cell (0,0,0) => z in [0,2]).
func _place_front_wall(srv) -> int:
	var bwall := _idx(srv._catalog, "bwall")
	srv._store.place(1, bwall, Vector3i(0, 0, 0), 0, -1, 1)
	return 1

func test_sledge_engineer_damages_wall() -> void:
	var srv := _make_server()
	_place_front_wall(srv)
	_client(srv, 1, Loadout.ENGINEER, Weapon.SMG)
	var eng := _add_pawn(srv, 1, Vector3(0, 0, -0.5), 0); eng.yaw = 0.0; eng.pitch = 0.0
	srv._resolve_melee(1)
	assert_eq(srv._sledge_hits, 1, "engineer sledge struck the wall")
	assert_true(srv._dmg >= 1, "structure took chunk damage")
	srv.free()

func test_assault_knife_does_not_demolish_wall() -> void:
	var srv := _make_server()
	_place_front_wall(srv)
	_client(srv, 1, Loadout.ASSAULT, Weapon.AR)
	var atk := _add_pawn(srv, 1, Vector3(0, 0, -0.5), 0); atk.yaw = 0.0; atk.pitch = 0.0
	srv._resolve_melee(1)   # no enemy + knife: nothing happens to the wall
	assert_eq(srv._sledge_hits, 0, "assault has no sledge")
	assert_eq(srv._dmg, 0, "knife does not carve a building wall")
	srv.free()

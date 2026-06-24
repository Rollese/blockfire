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

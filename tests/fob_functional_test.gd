extends TestCase
## M12-P3 FOB lifecycle, deterministic (AGENTS.md §10). No net, no AI: a BuildSiteStore + StructureStore
## + Fob + SpawnSelect loop reproducing server_main's FOB wiring (place -> cooperative build -> spawn
## enable/disable -> destroy/decay).

func _cat() -> PieceCatalog:
	return PieceCatalog.load_file("res://pieces/pieces.json")

func _idx(cat: PieceCatalog, id: String) -> int:
	for i in cat.size():
		if cat.name_of(i) == id: return i
	return -1

func _builder(pos: Vector3, fwd: Vector3, team: int = 0) -> Dictionary:
	return {"pos": pos, "fwd": fwd, "team": team}

# one build tick (FRIENDLY eligible builders advance; complete -> promote to store)
func _tick(sites: BuildSiteStore, store: StructureStore, builders: Array, now: int) -> Array:
	var built: Array = []
	for id in sites.ids():
		var s: Dictionary = sites.get_site(id)
		var center := BuildGrid.world_of(s["cell"])
		var n := 0
		for b in builders:
			if int(b["team"]) == int(s["team"]) and BuildSite.eligible(b["pos"], b["fwd"], center):
				n += 1
		if n < int(s["min_builders"]): continue
		s["build_progress"] = BuildSite.progress_step(float(s["build_progress"]), int(s["build_cost"]), n, int(s["min_builders"]), SimLoop.DT)
		if BuildSite.is_complete(float(s["build_progress"]), int(s["build_cost"])):
			built.append(id)
	for id in built:
		var s: Dictionary = sites.get_site(id)
		sites.remove(id)
		store.place(int(id), int(s["type"]), s["cell"], int(s["yaw"]), int(s["owner"]))
	return built

func _place_fob_site(sites: BuildSiteStore, cat: PieceCatalog, id: int, cell: Vector3i, owner: int, team: int) -> void:
	var t := _idx(cat, "fob")
	sites.add({"id": id, "owner": owner, "team": team, "type": t, "cell": cell, "yaw": 0,
		"build_progress": 0.0, "build_cost": cat.build_cost_of(t),
		"min_builders": cat.min_builders_of(t), "last_work_tick": 0})

func test_fob_needs_two_builders_then_completes_and_persists() -> void:
	var cat := _cat(); var sites := BuildSiteStore.new(); var store := StructureStore.new(cat)
	var cell := Vector3i(5, 0, 5)
	_place_fob_site(sites, cat, 4101, cell, 1, 0)
	var center := BuildGrid.world_of(cell)
	# Solo for 60 ticks: no progress (min_builders 2).
	var solo := [_builder(center, Vector3(0, 0, 1), 0)]
	for t in range(60): _tick(sites, store, solo, t)
	assert_eq(int(float(sites.get_site(4101)["build_progress"])), 0, "solo cannot advance the FOB")
	# Two builders -> completes within the match window.
	var two := [_builder(center, Vector3(0, 0, 1), 0), _builder(center, Vector3(0, 0, 1), 0)]
	var done := false
	for t in range(60, 600):
		if _tick(sites, store, two, t).size() > 0: done = true; break
	assert_true(done, "two builders complete the FOB")
	assert_true(sites.get_site(4101).is_empty(), "site consumed on completion")
	assert_false(store.get_record(4101).is_empty(), "FOB now a real structure (persists; not pawn-tied)")

func test_fob_spawn_enable_boundary() -> void:
	var center := Vector3(5, 0, 5)
	assert_true(Fob.spawn_enabled(center, [center + Vector3(Fob.VICINITY_RADIUS + 1.0, 0, 0)]), "enemy just outside -> enabled")
	assert_false(Fob.spawn_enabled(center, [center + Vector3(Fob.VICINITY_RADIUS - 1.0, 0, 0)]), "enemy just inside -> disabled")

func test_destroyed_fob_is_not_a_spawn_source() -> void:
	var cat := _cat(); var store := StructureStore.new(cat)
	store.place(4101, _idx(cat, "fob"), Vector3i(5, 0, 5), 0, 1)
	assert_false(store.get_record(4101).is_empty(), "FOB present")
	store.remove(4101)   # simulate M4 destruction
	assert_true(store.get_record(4101).is_empty(), "after destruction the FOB structure is gone")
	# A spawn picker handed no FOB source falls back to base.
	# Use a valid map: two bases + a neutral point at z=500 (never owned by team 0).
	var _mr := MapDef.from_json_string('{"points":[{"id":"A","pos":[0,0,500],"radius":15,"start_owner":-1}],"bases":[{"team":0,"pos":[-100,0,0],"radius":10},{"team":1,"pos":[100,0,0],"radius":10}]}')
	var m: MapDef = _mr["map"]
	var c := ConquestState.new(m)
	var r := SpawnSelect.choose(0, m, c, [], Vector3(20, 0, 0), [])
	assert_eq(r["kind"], SpawnSelect.SRC_BASE, "no FOB source -> base")

func test_abandoned_fob_site_decays() -> void:
	var cat := _cat(); var sites := BuildSiteStore.new(); var store := StructureStore.new(cat)
	_place_fob_site(sites, cat, 4101, Vector3i(5, 0, 5), 1, 0)
	# No builders for the decay window -> decayed() true (server then removes the site).
	assert_true(BuildSite.decayed(BuildSite.BUILD_SITE_DECAY_TICKS + 1, 0), "decay predicate fires after the window")
	assert_false(sites.get_site(4101).is_empty(), "site still present until the server removes it")

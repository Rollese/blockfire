extends TestCase
## M12-P2 cooperative shovel construction — deterministic loop over BuildSiteStore + BuildSite +
## StructureStore, no networking, no bot AI (the AGENTS.md §10 mechanic proof, mirroring
## server_buildings_functional_test.gd for destruction). This is the reference the server's
## _step_build_sites / shovel-repair / shovel-dismantle wiring must reproduce.

func _cat() -> PieceCatalog:
	return PieceCatalog.load_file("res://pieces/pieces.json")

func _idx(cat: PieceCatalog, id: String) -> int:
	for i in cat.size():
		if cat.name_of(i) == id:
			return i
	return -1

## A builder: world position + forward (facing) + team.
func _builder(pos: Vector3, fwd: Vector3, team: int = 0) -> Dictionary:
	return {"pos": pos, "fwd": fwd, "team": team}

## One server-tick of build work over the sites, exactly as server_main._step_build_sites will: count
## eligible FRIENDLY builders per site, advance via BuildSite, promote completed sites into `store`.
## Returns {built: Array[int] ids promoted, blocked_solo: int}.
func _tick_build(sites: BuildSiteStore, store: StructureStore, builders: Array, now_tick: int) -> Dictionary:
	var built: Array = []
	var blocked_solo := 0
	var to_decay: Array = []
	for id in sites.ids():
		var s: Dictionary = sites.get_site(id)
		var center := BuildGrid.world_of(s["cell"])
		var n := 0
		for b in builders:
			if int(b["team"]) == int(s["team"]) and BuildSite.eligible(b["pos"], b["fwd"], center):
				n += 1
		if n <= 0:
			if BuildSite.decayed(now_tick, int(s["last_work_tick"])):
				to_decay.append(id)
			continue
		if n < int(s["min_builders"]):
			blocked_solo += 1
			continue
		s["build_progress"] = BuildSite.progress_step(float(s["build_progress"]), int(s["build_cost"]), n, int(s["min_builders"]), SimLoop.DT)
		s["last_work_tick"] = now_tick
		if BuildSite.is_complete(float(s["build_progress"]), int(s["build_cost"])):
			built.append(id)
	for id in built:
		var s: Dictionary = sites.get_site(id)
		sites.remove(id)
		store.place(int(id), int(s["type"]), s["cell"], int(s["yaw"]), int(s["owner"]))
	for id in to_decay:
		sites.remove(id)
	return {"built": built, "blocked_solo": blocked_solo}

func _place_site(sites: BuildSiteStore, cat: PieceCatalog, id: int, type_idx: int, cell: Vector3i, owner: int, team: int) -> void:
	sites.add({"id": id, "owner": owner, "team": team, "type": type_idx, "cell": cell, "yaw": 0,
		"build_progress": 0.0, "build_cost": cat.build_cost_of(type_idx),
		"min_builders": cat.min_builders_of(type_idx), "last_work_tick": 0})

func test_small_site_builds_solo() -> void:
	var cat := _cat()
	var sites := BuildSiteStore.new()
	var store := StructureStore.new(cat)
	var sandbag := _idx(cat, "sandbag")
	var cell := Vector3i(3, 0, 0)
	_place_site(sites, cat, 1, sandbag, cell, 1, 0)
	# One builder standing on the cell, facing it.
	var center := BuildGrid.world_of(cell)
	var b := [_builder(center, Vector3(0, 0, 1), 0)]
	var promoted := false
	for t in range(200):
		var r := _tick_build(sites, store, b, t)
		if not (r["built"] as Array).is_empty():
			promoted = true
			break
	assert_true(promoted, "a small (min 1) site completes with a single shoveller")
	assert_eq(store.count(), 1, "completed site became a real structure")
	assert_eq(sites.count(), 0, "site removed on completion")

func test_large_site_blocked_solo_then_built_by_two() -> void:
	var cat := _cat()
	var sites := BuildSiteStore.new()
	var store := StructureStore.new(cat)
	var big := _idx(cat, "heavy_barricade")
	assert_true(big >= 0, "heavy_barricade present in catalog")
	var cell := Vector3i(5, 0, 0)
	_place_site(sites, cat, 1, big, cell, 1, 0)
	var center := BuildGrid.world_of(cell)
	# One builder: never completes; blocked_solo accrues.
	var solo := [_builder(center, Vector3(0, 0, 1), 0)]
	var blocked := 0
	for t in range(300):
		blocked += int(_tick_build(sites, store, solo, t)["blocked_solo"])
	assert_eq(store.count(), 0, "a large (min 2) site does NOT complete with one builder")
	assert_true(blocked >= 1, "solo work on a large site is reported blocked")
	# Two builders standing just south of the site, both facing it (+Z toward center).
	var pair := [_builder(center + Vector3(0.4, 0, -1.0), Vector3(0, 0, 1), 0),
		_builder(center + Vector3(-0.4, 0, -1.0), Vector3(0, 0, 1), 0)]
	var built := false
	for t in range(400):
		if not (_tick_build(sites, store, pair, 300 + t)["built"] as Array).is_empty():
			built = true
			break
	assert_true(built, "two simultaneous builders complete the large site")
	assert_eq(store.count(), 1, "large site promoted to a real structure")

func test_abandoned_site_decays() -> void:
	var cat := _cat()
	var sites := BuildSiteStore.new()
	var store := StructureStore.new(cat)
	_place_site(sites, cat, 1, _idx(cat, "sandbag"), Vector3i(7, 0, 0), 1, 0)
	for t in range(BuildSite.BUILD_SITE_DECAY_TICKS + 2):
		_tick_build(sites, store, [], t)   # nobody shovels
	assert_eq(sites.count(), 0, "an abandoned, un-worked site decays away")
	assert_eq(store.count(), 0, "and never becomes a structure")

func test_enemy_shovel_dismantles_a_finished_structure() -> void:
	# Dismantle reuses the M4 melee damage path on the finished structure (slow but possible with
	# only a shovel). Proven here at the store level (SRC_MELEE damage_chunks until destroyed).
	var cat := _cat()
	var store := StructureStore.new(cat)
	var wall := _idx(cat, "wall")
	var cell := Vector3i(8, 0, 0)
	store.place(1, wall, cell, 0, 1)
	var center := BuildGrid.cell_min(cell) + Vector3(1.0, 1.0, 1.0)
	# A shoveller carves the wall with the melee path (the no-explosives demolition route). The server
	# rate-limits the per-tick radius so it is slow; here we prove the mechanic reaches destruction.
	var hit_once := false
	var destroyed := false
	for _i in range(400):
		var r := store.damage_chunks(1, PieceCatalog.SRC_MELEE, center, BuildSite.SHOVEL_RANGE)
		hit_once = hit_once or r["hit"]
		if r["destroyed"]:
			destroyed = true
			break
	assert_true(hit_once, "shovel (melee) carves an enemy fortification")
	assert_true(destroyed, "sustained shovelling fully digs it down")
	store.remove(1)
	assert_eq(store.count(), 0, "dismantled structure removed")

func test_friendly_shovel_repairs_a_holed_structure() -> void:
	var cat := _cat()
	var store := StructureStore.new(cat)
	var wall := _idx(cat, "wall")
	var cell := Vector3i(9, 0, 0)
	store.place(1, wall, cell, 0, 1)
	var impact := BuildGrid.cell_min(cell) + Vector3(0.5, 0.5, 0.5)   # the M4/M11-proven impact recipe
	var dmg := store.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, impact, 0.7)
	assert_true(dmg["hit"], "explosive holes the wall")
	var holed := int(store.get_record(1)["chunks"])
	var rep := store.repair_chunks(1, impact, 0.7)
	assert_true(rep["changed"], "shovel-repair re-sets cleared chunks")
	assert_true(int(store.get_record(1)["chunks"]) != holed, "mask grew back toward full")
	assert_true(int(store.get_record(1)["chunks"]) > holed, "repaired mask has more intact chunks")

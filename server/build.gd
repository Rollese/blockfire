class_name ServerBuild
extends RefCounted
## Build/FOB pipeline, extracted from server_main (batch 5 D1): build-site placement
## (M12-P2 shovel construction), per-tick site/shovel steps, completion into the structure
## store, dismantle/remove, and the squad-leader FOB lifecycle (place/remove/reconcile +
## the deploy-side read helpers). Owns the site store and FOB registry; structure damage,
## wire emission and the store itself stay on the server (back-ref `srv`).

var srv   # ServerMain back-ref (untyped: server_main.gd declares no class_name)

const MAX_SITES_PER_PLAYER := 4

var sites := BuildSiteStore.new()   # M12-P2: active under-construction build sites
var fobs: Dictionary = {}           # "team:squad" -> {squad, team, id, cell, built}


func _init(server) -> void:
	srv = server


func fob_built_alive(team: int, squad: int) -> bool:
	var rec := fob_for(team, squad)
	return not rec.is_empty() and bool(rec["built"]) and not srv._store.get_record(int(rec["id"])).is_empty()

## The squad's FOB world position IFF built + alive + enemy-free; else null. Pure query (no side
## effects) — fob_disabled is tallied by the caller on the spawn-decision path (see _select_spawn).
func spawnable_fob_pos(team: int, squad: int):
	if not fob_built_alive(team, squad): return null
	var rec := fob_for(team, squad)
	var center := BuildGrid.world_of(rec["cell"])
	var enemies: Array = []
	for oid in srv._clients:
		var op: Pawn = srv._sim.world.get_pawn(oid)
		if op != null and op.alive and op.team != team:
			enemies.append(op.pos)
	return center if Fob.spawn_enabled(center, enemies) else null


func fob_candidates(team: int) -> Array:
	var out: Array = []
	for key in fobs:
		var rec: Dictionary = fobs[key]
		if int(rec["team"]) != team or not bool(rec["built"]): continue
		var pos = spawnable_fob_pos(team, int(rec["squad"]))
		out.append({"squad": int(rec["squad"]), "pos": BuildGrid.world_of(rec["cell"]),
			"enabled": pos != null})
	return out


func handle_build_request(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = srv._peer_to_id.get(peer, 0)
	if id == 0 or not srv._clients.has(id): return
	var c = srv._clients[id]
	var p: Pawn = srv._sim.world.get_pawn(id)
	if p == null or not p.alive: return
	var d := Protocol.decode_build_request(bytes)
	var type: int = d["type"]
	if type < 0 or type >= srv._catalog.size(): return
	if int(d["yaw"]) < 0 or int(d["yaw"]) >= BuildGrid.YAW_STEPS: return   # reject malformed/out-of-range yaw (map path validates; player path did not)
	var cell: Vector3i = d["cell"]
	var v: Dictionary = srv._store.validate_place(cell, p.pos, srv._sim.tick, c["last_build_tick"], Pawn.WORLD_HALF)
	if not v["ok"]: return
	if srv._catalog.is_structural(type): return   # players build only fortifications, not building pieces
	if sites.occupied(cell): return          # already a site there
	# Per-player SITE cap: recycle the oldest unfinished site.
	if sites.owner_count(id) >= MAX_SITES_PER_PLAYER:
		var oldid := sites.oldest_id(id)
		if oldid != 0:
			var ocell: Vector3i = sites.get_site(oldid)["cell"]
			sites.remove(oldid)
			srv._emit_structure_delta(Protocol.OP_REMOVE, {"id": oldid}, ocell)
	var sid: int = srv._next_struct_id
	srv._next_struct_id += 1
	c["last_build_tick"] = srv._sim.tick
	var site := {"id": sid, "owner": id, "team": p.team, "type": type, "cell": cell, "yaw": int(d["yaw"]),
		"build_progress": 0.0, "build_cost": srv._catalog.build_cost_of(type),
		"min_builders": srv._catalog.min_builders_of(type), "last_work_tick": srv._sim.tick}
	sites.add(site)
	srv._stats.builds += 1
	srv._emit_structure_delta(Protocol.OP_PLACE, site_wire_record(site), cell)

## Wire record for an under-construction site: StructureStore record shape + the M12-P2 fields.
func site_wire_record(site: Dictionary) -> Dictionary:
	return {"id": site["id"], "type": site["type"], "cell": site["cell"], "yaw": site["yaw"],
		"chunks": ChunkMask.full_mask(srv._catalog.chunk_grid_of(int(site["type"]))),
		"building_id": 0, "owner": site["owner"],
		"under_construction": 1, "build_progress": int(site["build_progress"])}

func emit_structure_progress(id: int, progress: int, cell: Vector3i) -> void:
	var region: Vector2i = srv._store.region_of(cell)
	var bytes := Protocol.encode_structure_progress(id, progress)
	for cid in srv._clients:
		if srv._clients[cid]["known_regions"].has(region):
			srv._net.send_to(srv._clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

## M12-P3 FOB registry helpers.
func fob_key(team: int, squad: int) -> String:
	return "%d:%d" % [team, squad]

func fob_for(team: int, squad: int) -> Dictionary:
	return fobs.get(fob_key(team, squad), {})

func fob_type_index() -> int:
	for i in srv._catalog.size():
		if srv._catalog.name_of(i) == "fob":
			return i
	return -1

## M12-P3: squad leader places a FOB build site. Leader-only, one-per-squad (replace), CP/base
## exclusion, then reuses the M12-P2 cooperative build path (promotes to a bunker on completion).
func handle_place_fob(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = srv._peer_to_id.get(peer, 0)
	if id == 0 or not srv._clients.has(id): return
	var c = srv._clients[id]
	var p: Pawn = srv._sim.world.get_pawn(id)
	if p == null or not p.alive: return
	var team: int = int(c["team"])
	var squad: int = int(c["squad"])
	if srv._squads.leader_of(team, squad) != id: return    # leader-only (authoritative)
	var d := Protocol.decode_place_fob(bytes)
	if int(d["yaw"]) < 0 or int(d["yaw"]) >= BuildGrid.YAW_STEPS: return
	var cell: Vector3i = d["cell"]
	var center := BuildGrid.world_of(cell)
	if not Fob.placement_ok(center, team, srv._map, srv._conquest): return
	var v: Dictionary = srv._store.validate_place(cell, p.pos, srv._sim.tick, c["last_build_tick"], Pawn.WORLD_HALF)
	if not v["ok"]: return
	if sites.occupied(cell): return
	var fob_type := fob_type_index()
	if fob_type < 0: return
	# One FOB per squad: drop the existing site/structure first.
	remove_squad_fob(team, squad)
	var sid: int = srv._next_struct_id
	srv._next_struct_id += 1
	c["last_build_tick"] = srv._sim.tick
	var site := {"id": sid, "owner": id, "team": team, "type": fob_type, "cell": cell, "yaw": int(d["yaw"]),
		"build_progress": 0.0, "build_cost": srv._catalog.build_cost_of(fob_type),
		"min_builders": srv._catalog.min_builders_of(fob_type), "last_work_tick": srv._sim.tick}
	sites.add(site)
	fobs[fob_key(team, squad)] = {"squad": squad, "team": team, "id": sid, "cell": cell, "built": false}
	srv._emit_structure_delta(Protocol.OP_PLACE, site_wire_record(site), cell)

func handle_remove_fob(peer: ENetPacketPeer) -> void:
	var id = srv._peer_to_id.get(peer, 0)
	if id == 0 or not srv._clients.has(id): return
	var c = srv._clients[id]
	var team: int = int(c["team"]); var squad: int = int(c["squad"])
	if srv._squads.leader_of(team, squad) != id: return
	remove_squad_fob(team, squad)

## Remove a squad's FOB entity (under-construction site OR completed structure) + registry record.
func remove_squad_fob(team: int, squad: int) -> void:
	var rec := fob_for(team, squad)
	if rec.is_empty(): return
	var fid := int(rec["id"])
	var cell: Vector3i = rec["cell"]
	if sites.get_site(fid).is_empty() == false:
		sites.remove(fid)
		srv._emit_structure_delta(Protocol.OP_REMOVE, {"id": fid}, cell)
	elif srv._store.get_record(fid).is_empty() == false:
		srv._store.remove(fid)
		srv._emit_structure_delta(Protocol.OP_REMOVE, {"id": fid}, cell)
	fobs.erase(fob_key(team, squad))

## M12-P3: detect FOB lifecycle transitions against the live stores (robust to every removal path):
## site->built (tally fobs_built), built->gone (tally fobs_destroyed), site->gone-before-built (decay).
func reconcile_fobs() -> void:
	if fobs.is_empty(): return
	var drop: Array = []
	for key in fobs:
		var rec: Dictionary = fobs[key]
		var fid := int(rec["id"])
		if not bool(rec["built"]):
			if not srv._store.get_record(fid).is_empty():
				rec["built"] = true
				srv._stats.fobs_built += 1
			elif sites.get_site(fid).is_empty():
				drop.append(key)   # site decayed/removed before completing
		else:
			if srv._store.get_record(fid).is_empty():
				srv._stats.fobs_destroyed += 1
				drop.append(key)   # bunker destroyed via M4 path / dismantle / recycle
	for key in drop:
		fobs.erase(key)

## M12-P2: advance build sites from eligible shovellers; complete -> promote to StructureStore;
## decay abandoned sites; then repair/dismantle finished structures for the remaining shovellers.
func step_build_sites() -> void:
	# Pawns holding BTN_SHOVEL this tick.
	var shov := {}
	for cid in srv._clients:
		var inp = srv._clients[cid]["last_input"]
		if inp == null or (int(inp["buttons"]) & InputCommand.BTN_SHOVEL) == 0:
			continue
		var pp: Pawn = srv._sim.world.get_pawn(cid)
		if pp == null or not pp.alive or pp.is_downed:
			continue
		shov[cid] = {"pos": pp.pos, "fwd": Combat._forward(pp.yaw, pp.pitch), "team": pp.team}
	if sites.count() == 0 and shov.is_empty():
		return
	var built: Array = []
	var decayed: Array = []
	var busy := {}   # cid -> true: contributed to a site this tick (skip for structure-shovel)
	for id in sites.ids():
		var s: Dictionary = sites.get_site(id)
		var center := BuildGrid.world_of(s["cell"])
		var n := 0
		for cid in shov:
			var b = shov[cid]
			if int(b["team"]) != int(s["team"]):
				continue
			if BuildSite.eligible(b["pos"], b["fwd"], center):
				n += 1
				busy[cid] = true
		if n <= 0:
			if BuildSite.decayed(srv._sim.tick, int(s["last_work_tick"])):
				decayed.append(id)
			continue
		if n < int(s["min_builders"]):
			srv._stats.build_blocked_solo += 1
			continue
		var before := float(s["build_progress"])
		var after := BuildSite.progress_step(before, int(s["build_cost"]), n, int(s["min_builders"]), SimLoop.DT)
		s["build_progress"] = after
		s["last_work_tick"] = srv._sim.tick
		if int(after / 6.0) != int(before / 6.0):
			emit_structure_progress(int(id), int(after), s["cell"])
		if BuildSite.is_complete(after, int(s["build_cost"])):
			built.append(id)
	for id in built:
		complete_site(int(id))
	for id in decayed:
		var dcell: Vector3i = sites.get_site(int(id))["cell"]
		sites.remove(int(id))
		srv._emit_structure_delta(Protocol.OP_REMOVE, {"id": int(id)}, dcell)
	step_shovel_structures(shov, busy)
	reconcile_fobs()   # M12-P3: detect FOB site->built / built->destroyed / pre-build decay

func complete_site(id: int) -> void:
	var s: Dictionary = sites.get_site(id)
	if s.is_empty():
		return
	sites.remove(id)
	# Cap finished pieces per owner (recycle oldest), then promote into the real structure store.
	if srv._store.owner_count(int(s["owner"])) >= StructureStore.MAX_PIECES_PER_PLAYER:
		var oldp: int = srv._store.oldest_id(int(s["owner"]))
		if oldp != 0:
			var oc: Vector3i = srv._cell_of_struct(oldp)
			srv._store.recycle_oldest(int(s["owner"]))
			srv._emit_structure_delta(Protocol.OP_REMOVE, {"id": oldp}, oc)
	var rec: Dictionary = srv._store.place(id, int(s["type"]), s["cell"], int(s["yaw"]), int(s["owner"]))
	if rec.is_empty():
		return   # lost the cell race
	var wire := rec.duplicate()
	wire["under_construction"] = 0
	wire["build_progress"] = int(s["build_cost"])
	srv._emit_structure_delta(Protocol.OP_PLACE, wire, s["cell"])
	if int(s["min_builders"]) >= 2:
		srv._stats.built_large += 1
	else:
		srv._stats.built_small += 1

## Shovellers not busy building a site repair a friendly / dismantle an enemy finished structure they
## are aiming at within reach. Reuses the M4 melee damage path (dismantle) + repair_chunks (repair).
func step_shovel_structures(shov: Dictionary, busy: Dictionary) -> void:
	for cid in shov:
		if busy.has(cid):
			continue
		var b = shov[cid]
		var hit: Dictionary = srv._store.march(b["pos"], b["fwd"], BuildSite.SHOVEL_RANGE)
		if not hit["hit"]:
			continue
		var sidx := int(hit["id"])
		var rec: Dictionary = srv._store.get_record(sidx)
		if rec.is_empty():
			continue
		var impact: Vector3 = (b["pos"] as Vector3) + (b["fwd"] as Vector3).normalized() * float(hit["dist"])
		var op: Pawn = srv._sim.world.get_pawn(int(rec["owner"]))
		var struct_team := op.team if op != null else int(b["team"])
		if int(b["team"]) == struct_team:
			var rep: Dictionary = srv._store.repair_chunks(sidx, impact, 0.9)
			if rep["changed"]:
				srv._stats.repaired += 1
				srv._emit_structure_delta(Protocol.OP_CHUNK, {"id": sidx, "mask": int(rep["mask"])}, rec["cell"])
		else:
			if not srv._catalog.takes_damage(int(rec["type"]), PieceCatalog.SRC_MELEE):
				continue
			var dmg: Dictionary = srv._store.damage_chunks(sidx, PieceCatalog.SRC_MELEE, impact, 0.6)
			if dmg["destroyed"]:
				srv._stats.dismantled += 1
				srv._pending_removes.append({"id": sidx, "cell": rec["cell"]})
			elif dmg["holed"]:
				srv._dmg_touched[sidx] = true

func handle_build_remove(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = srv._peer_to_id.get(peer, 0)
	if id == 0 or not srv._clients.has(id): return
	var rid: int = Protocol.decode_build_remove(bytes)["id"]
	var rec: Dictionary = srv._store.get_record(rid)
	if rec.is_empty() or int(rec["owner"]) != id: return
	var cell: Vector3i = rec["cell"]
	srv._store.remove(rid)
	srv._stats.removes += 1
	srv._emit_structure_delta(Protocol.OP_REMOVE, {"id": rid}, cell)

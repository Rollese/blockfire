extends SceneTree
## Standalone screenshot harness for M11 destruction FEEL validation. Stamps conquest_town's REAL
## buildings into a client StructureStore (mirrors server_main boot), feeds them to a WorldView +
## WorldRenderer, then drives ONE building through the destruction arc — intact, a window-sized
## see-through HOLE (carved with the sim's own ChunkMask.clear_in_radius so it matches the sim), a
## wide BREACH, and a whole-building COLLAPSE (footprint-scaled cinematic + rubble field). Captures a
## PNG per stage to eyeball the destruction feel (H1 hole-aware geometry + scaled collapse).
##   godot --path . -s res://tools/render_destruct_shots.gd --rendering-driver <opengl3|vulkan>
## Deterministic (no networking, no bots). A QA tool, not a game path.

const MAP_PATH := "res://maps/conquest_town.json"

func _initialize() -> void:
	var scene: PackedScene = load("res://client/client.tscn")
	var world: Node3D = scene.instantiate() as Node3D
	get_root().add_child(world)
	var cam: Camera3D = world.get_node("Camera3D") as Camera3D
	cam.current = true

	var map: MapDef = MapDef.load_file(MAP_PATH)
	if map == null:
		push_error("failed to load map"); quit(1); return
	var grid = Terrain.load_for_map(map, "res://maps", Callable())

	var cat: PieceCatalog = PieceCatalog.load_file("res://pieces/pieces.json")
	if cat == null:
		push_error("failed to load piece catalog"); quit(1); return

	var r := WorldRenderer.new()
	world.add_child(r)
	r.piece_catalog = cat
	r.set_terrain(grid)
	r.setup(map, cam)

	# --- Stamp every building into a StructureStore (mirror server_main.gd:255-288). Accumulate the
	#     returned records so we can hand the client a single baseline. Track per-building piece lists.
	var store := StructureStore.new(cat)
	store.terrain = grid
	var recs: Array = []
	var by_building: Dictionary = {}   # bid -> [rec]
	var next_sid := 1
	var next_bid := 1
	for b in map.buildings:
		var pres: Dictionary = BuildingCatalog.load_file("res://buildings/%s.json" % b["prefab"], cat)
		if not bool(pres.get("ok", false)):
			continue
		var origin: Vector3i = b["origin_cell"]
		var inst_yaw: int = int(b.get("yaw", 0))
		var bid := next_bid
		next_bid += 1
		by_building[bid] = []
		for piece in pres["prefab"]["pieces"]:
			var cell: Vector3i = origin + _rotate_offset(piece["offset"], inst_yaw)
			var placed: Dictionary = store.place(next_sid, int(piece["type"]), cell,
				(int(piece.get("yaw", 0)) + inst_yaw) % BuildGrid.YAW_STEPS, -1, bid)
			next_sid += 1
			if not placed.is_empty():
				recs.append(placed)
				(by_building[bid] as Array).append(placed)

	# --- Feed the client store via a baseline (region header is cosmetic; all recs are inserted).
	var wv := WorldView.new()
	wv.apply_structure_baseline(Protocol.encode_structure_baseline(Vector2i.ZERO, recs))

	# --- Pick the target building: the one with the MOST wall pieces (biggest, most dramatic).
	var target_bid := _pick_wall_building(by_building)
	if target_bid == 0:
		push_error("no building with walls found"); quit(1); return
	var trecs: Array = by_building[target_bid]
	var centroid := _centroid(r, trecs)
	print("target building bid=", target_bid, " pieces=", trecs.size(), " centroid=", centroid)

	# Nodes added during _initialize only become "inside tree" after a frame — settle before we touch
	# the camera's global transform (else global_position/look_at error and the shot stays at origin).
	await _settle()

	# --- Choose a camera-facing wall piece near eye height to carve (the "shoot a hole" demo), then
	#     frame the camera ~5 m directly OUT from that wall so a sub-cell hole is clearly visible.
	var wall_rec := _nearest_wall(r, trecs, centroid + Vector3(11, 3.5, 11))
	var cam_pos := centroid + Vector3(11.0, 3.5, 11.0)
	var wall_pt := centroid + Vector3(0, 1.0, 0)
	if not wall_rec.is_empty():
		wall_pt = r._structure_xform(wall_rec).origin + Vector3(0, 1.0, 0)
		var outward := (Vector3(wall_pt.x, 0, wall_pt.z) - Vector3(centroid.x, 0, centroid.z)).normalized()
		cam_pos = wall_pt + outward * 5.0 + Vector3(0, 0.6, 0)
	cam.global_position = cam_pos
	cam.look_at(wall_pt, Vector3.UP)

	var dir := "user://destruct_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var now := 1.0

	# Stage 0: intact. Sync builds the batches AND populates _building_footprint (needed for collapse).
	r._sync_structure_pool(wv, now)
	await _settle()
	await _capture(cam, dir, "0_intact")

	# Stage 1: shoot a WINDOW-SIZED hole. Carve with the sim's own ChunkMask.clear_in_radius at a point
	# on the wall face (exactly how a bullet/blast carves) so the rendered hole matches the sim. With
	# H1 this PROMOTES the wall to per-chunk geometry -> a real see-through hole appears.
	if not wall_rec.is_empty():
		var pid := int(wall_rec["id"])
		var ty := int(wall_rec["type"])
		var cgrid := cat.chunk_grid_of(ty)
		var fh := BuildGrid.CELL_SIZE * (0.5 if cat.is_half(ty) else 1.0)
		var cell := wall_rec["cell"] as Vector3i
		var yaw := int(wall_rec["yaw"])
		var impact := ChunkMask.chunk_center(cell, yaw, cgrid / 2, cgrid / 2, cgrid, fh)   # face centre
		var carved := ChunkMask.clear_in_radius(int(wall_rec["chunks"]), cell, yaw, cgrid, fh, impact, 0.6)
		now += 0.5
		wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_CHUNK, {"id": pid, "mask": carved}))
		r._sync_structure_pool(wv, now)
		await _settle()
		await _capture(cam, dir, "1_hole")

		# Stage 2: widen it to a big breach (radius 1.3 m) — most of the wall gone, jagged chunk edges.
		var breach := ChunkMask.clear_in_radius(carved, cell, yaw, cgrid, fh, impact, 1.3)
		now += 0.5
		wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_CHUNK, {"id": pid, "mask": breach}))
		r._sync_structure_pool(wv, now)
		await _settle()
		await _capture(cam, dir, "2_breach")

	# Stage 3: whole-building COLLAPSE remnant — mirror the SERVER's _collapse_building: remove every
	# building piece from BOTH the client view AND the sim store (so the footprint cells free up), then
	# stamp indestructible walkable `brubble` across the footprint ground cells + replicate via OP_PLACE.
	# NOTE the bug this harness previously hid: without removing from `store` first, place() hit occupied
	# cells and skipped every rubble piece.
	now += 0.5
	var brub := cat.index_of("brubble")
	for rec in trecs:
		wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": int(rec["id"])}))
		store.remove(int(rec["id"]))
	var seen := {}
	var placed_rubble := 0
	for rec in trecs:
		var c := rec["cell"] as Vector3i
		var xz := Vector2i(c.x, c.z)
		if seen.has(xz):
			continue
		seen[xz] = true
		var rr: Dictionary = store.place(next_sid, brub, Vector3i(c.x, 0, c.z), 0, 0, 0)
		next_sid += 1
		if not rr.is_empty():
			wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_PLACE, rr))
			placed_rubble += 1
	r._sync_structure_pool(wv, now)
	# Report whether the renderer actually built nodes for the brubble type (24) — the real diagnostic.
	var brub_key := ""
	for k in r._struct_groups:
		if String(k).begins_with("%d:" % brub):
			brub_key = k
	print("brubble placed=", placed_rubble, " render_group=", brub_key,
		" mmis=", (r._struct_groups[brub_key]["mmis"].size() if brub_key != "" else -1))
	# Top-down so the ground rubble field is clearly visible.
	cam.global_position = centroid + Vector3(2.0, 34.0, 2.0)
	cam.look_at(Vector3(centroid.x, 0.0, centroid.z), Vector3(0, 0, -1))
	await _settle()
	await _capture(cam, dir, "3_rubble")

	print("done")
	quit(0)


func _rotate_offset(off: Vector3i, yaw_step: int) -> Vector3i:
	var quarters := (yaw_step % BuildGrid.YAW_STEPS) / (BuildGrid.YAW_STEPS / 4)
	var x := off.x
	var z := off.z
	for _i in range(quarters):
		var nx := -z
		var nz := x
		x = nx
		z = nz
	return Vector3i(x, off.y, z)


## Building with the most wall pieces (bwall*), so carve/remove/collapse are as visible as possible.
func _pick_wall_building(by_building: Dictionary) -> int:
	var best_bid := 0
	var best_walls := -1
	for bid in by_building:
		var walls := 0
		for rec in (by_building[bid] as Array):
			if _piece_id(rec).begins_with("bwall"):
				walls += 1
		if walls > best_walls:
			best_walls = walls
			best_bid = int(bid)
	return best_bid


func _piece_id(rec: Dictionary) -> String:
	var t := int(rec.get("type", 0))
	return WorldRenderer.STRUCT_TYPE_ID[t] if t < WorldRenderer.STRUCT_TYPE_ID.size() else "wall"


func _centroid(r: WorldRenderer, recs: Array) -> Vector3:
	var sum := Vector3.ZERO
	for rec in recs:
		sum += r._structure_xform(rec).origin
	return sum / maxf(1.0, float(recs.size()))


## Camera-facing wall piece nearest the camera, biased toward eye height (cell.y in {0,1}).
## Set BF_HIGH_WALL=1 to instead target the HIGHEST wall (roofline) — repro for the roof stick-through.
func _nearest_wall(r: WorldRenderer, recs: Array, cam_pos: Vector3) -> Dictionary:
	var high := OS.get_environment("BF_HIGH_WALL") == "1"
	var best: Dictionary = {}
	var best_d := INF
	var best_y := -999
	for rec in recs:
		if not _piece_id(rec).begins_with("bwall"):
			continue
		var cy := (rec["cell"] as Vector3i).y
		if high:
			if cy > best_y:
				best_y = cy; best = rec
			continue
		if cy > 1:
			continue
		var d := r._structure_xform(rec).origin.distance_to(cam_pos)
		if d < best_d:
			best_d = d
			best = rec
	return best


## The vertical column of pieces sharing the wall's (x,z) cell — remove them together for a taller gap.
func _column_ids(recs: Array, wall_rec: Dictionary) -> Array:
	var wc := wall_rec["cell"] as Vector3i
	var out: Array = []
	for rec in recs:
		var c := rec["cell"] as Vector3i
		if c.x == wc.x and c.z == wc.z:
			out.append(int(rec["id"]))
	return out


func _settle() -> void:
	for i in range(6):
		await process_frame


func _capture(cam: Camera3D, dir: String, name: String) -> void:
	var img := get_root().get_texture().get_image()
	var path := "%s/%s.png" % [dir, name]
	img.save_png(path)
	print("wrote ", ProjectSettings.globalize_path(path))

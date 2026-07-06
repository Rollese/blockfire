extends SceneTree
## Standalone screenshot harness for M11 destruction FEEL validation. Stamps conquest_town's REAL
## buildings into a client StructureStore (mirrors server_main boot), feeds them to a WorldView +
## WorldRenderer, then drives ONE building through the full destruction arc — intact, mid-carve
## (chunk mask cleared), a wall piece fully removed (the best "hole" the current renderer can make:
## a whole 2 m cell), and a whole-building COLLAPSE (cinematic burst + rubble mound). Captures a PNG
## at each stage so the current cosmetic feel can be eyeballed BEFORE changing anything.
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

	# --- Seat the camera ~11 m out from the centroid, slightly above eye height, looking at it.
	var cam_pos := centroid + Vector3(11.0, 3.5, 11.0)
	cam.global_position = cam_pos
	cam.look_at(centroid + Vector3(0, 1.0, 0), Vector3.UP)

	# --- Choose a camera-facing wall piece near eye height to carve/remove (the "hole" demo).
	var wall_rec := _nearest_wall(r, trecs, cam_pos)

	var dir := "user://destruct_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var now := 1.0

	# Stage 0: intact. Sync builds the batches AND populates _building_footprint (needed for collapse).
	r._sync_structure_pool(wv, now)
	await _settle()
	await _capture(cam, dir, "0_intact")

	# Stage 1: mid-carve — clear ~half the chunk bits of the facing wall (drops it a damage bucket:
	# it darkens + sprouts a base rubble pile, but still renders + blocks WHOLE). This is the current
	# "damaged wall" look. No sub-cell hole exists.
	if not wall_rec.is_empty():
		var pid := int(wall_rec["id"])
		var carved := int(wall_rec.get("chunks", -1)) & ~0x00000000FFFFFFFF   # clear low 32 of 64 bits
		now += 0.5
		wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_CHUNK, {"id": pid, "mask": carved}))
		r._sync_structure_pool(wv, now)
		await _settle()
		await _capture(cam, dir, "1_carved")

	# Stage 2: the best "hole" the current renderer can make — fully remove the facing wall piece +
	# its vertical neighbour so a full 2 m x 4 m cell gap opens (all-or-nothing, no sub-cell edges).
	if not wall_rec.is_empty():
		now += 0.5
		for pid2 in _column_ids(trecs, wall_rec):
			wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": pid2}))
		r._sync_structure_pool(wv, now)
		await _settle()
		await _capture(cam, dir, "2_wall_removed")

	# Stage 3: whole-building COLLAPSE — cinematic dust/debris burst + rubble mound swap.
	now += 0.5
	wv.apply_collapse(target_bid)
	r._sync_structure_pool(wv, now)
	await _settle()
	await _capture(cam, dir, "3_collapsed")

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
func _nearest_wall(r: WorldRenderer, recs: Array, cam_pos: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for rec in recs:
		if not _piece_id(rec).begins_with("bwall"):
			continue
		var cy := (rec["cell"] as Vector3i).y
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

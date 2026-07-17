@tool
extends Node3D
## Renders a MapDocument with the REAL runtime art kits so the editor viewport shows what the game
## will show. WYSIWYG is the whole point of M22 — the previous authoring loop was blind, which is
## exactly why the generated maps were bad.
##
## RULE: never fork an art kit for the editor. Buildings instantiate exactly as
## client/art/preview/map_preview.gd does (raw building JSON pieces -> BuildingKit.build); scenery
## goes through the same SceneryKit.build entry point client/world_renderer.gd uses (it routes
## tree_/rock_ ids to TreeKit/RockKit internally). A preview that can drift from the shipping renderer
## is worse than no preview at all. See docs/superpowers/specs/2026-07-16-map-editor-design.md §4.

## Rebuild the whole preview from `doc`. Full rebuild (not incremental): a map is a few thousand
## meshes and correctness beats speed here — an incremental path that misses an edit shows the owner
## a lie. Revisit only if authoring actually feels slow.
func rebuild(doc) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	if doc == null:
		return
	_build_buildings(doc)
	_build_scenery(doc)

## Instantiate each building's pieces via the shipping BuildingKit, exactly as map_preview.gd does:
## read the raw building JSON (string piece `type`), place each piece at its cell centre, and rotate
## non-corner pieces by their yaw step. bucket 3 == full tint (an undamaged piece).
func _build_buildings(doc) -> void:
	for b in doc.buildings:
		var prefab := String(b.get("prefab", ""))
		var path := "res://buildings/%s.json" % prefab
		if not FileAccess.file_exists(path):
			push_error("[editor_preview] unknown prefab '%s'" % prefab)
			continue
		var bdata = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(bdata) != TYPE_DICTIONARY or not bdata.has("pieces"):
			continue
		var oc = b["origin_cell"]
		var oc_x: int = oc.x if oc is Vector3i else int(oc[0])
		var oc_z: int = oc.z if oc is Vector3i else int(oc[2])
		var root := Node3D.new()
		root.name = "Prefab_%s" % prefab
		for piece in bdata["pieces"]:
			var off = piece["offset"]
			var cell := Vector3i(oc_x + int(off[0]), int(off[1]), oc_z + int(off[2]))
			var pid := String(piece["type"])
			var ystep := int(piece.get("yaw", 0))
			var node: Node3D = BuildingKit.build(pid, 3, false, ystep)
			node.position = Vector3((float(cell.x) + 0.5) * BuildGrid.CELL_SIZE,
				float(cell.y) * BuildGrid.CELL_SIZE, (float(cell.z) + 0.5) * BuildGrid.CELL_SIZE)
			if pid != "bwall_corner":
				node.rotation = Vector3(0.0, BuildGrid.yaw_radians(ystep), 0.0)
			root.add_child(node)
		add_child(root)

## Scenery/props through the same SceneryKit.build entry point the game uses. tree_/rock_ ids resolve
## to procedural TreeKit/RockKit geometry inside SceneryKit; an unknown id returns null and is skipped
## (the owner may be mid-typing an id). Seed matches world_renderer.gd so a tree looks identical here.
func _build_scenery(doc) -> void:
	var palette: Dictionary = doc.scenery_palette if doc.scenery_palette is Dictionary else {}
	for s in doc.scenery:
		var sid := String(s.get("id", ""))
		var pos = s["pos"]
		var world_pos: Vector3 = pos if pos is Vector3 else Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		var sc_seed := hash(sid + str(world_pos))
		var node := SceneryKit.build(sid, palette, String(s.get("palette", "")), sc_seed)
		if node == null:
			continue
		node.position = world_pos
		node.rotation.y = float(s.get("yaw", 0.0))
		var sc_scale := float(s.get("scale", 1.0))
		if absf(sc_scale - 1.0) > 0.001:
			node.scale = Vector3(sc_scale, sc_scale, sc_scale)
		add_child(node)

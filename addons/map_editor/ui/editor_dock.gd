@tool
extends Control
## M22 map-editor dock: tool selector + the current MapDocument. Built in code (no .tscn) so the
## whole UI is reviewable as text and cannot drift from the script.
##
## Holds NO map logic — every mutation goes through shared/mapedit/. See map_editor_plugin.gd.

const MapDocument := preload("res://shared/mapedit/map_document.gd")
const MapValidator := preload("res://shared/mapedit/map_validator.gd")
const TerrainBrush := preload("res://shared/mapedit/terrain_brush.gd")

enum Mode { TERRAIN, BUILDING, PROP, MARKER, ROAD }

var undo_redo: EditorUndoRedoManager = null
var doc: MapDocument = null
var mode: Mode = Mode.TERRAIN

var current_prefab: String = "cottage"
var current_prop: String = "tree_type3_02"
var current_road: int = 0
var current_road_width: float = 8.0
var current_yaw: int = 0
var brush_radius: float = 8.0
var brush_strength: float = 0.5
var brush_mode: int = 0   # TerrainBrush.Mode.RAISE
## Which marker a MARKER-mode click moves: {"kind": "point"|"base", "index": int}.
var current_marker: Dictionary = {"kind": "point", "index": 0}

var _mode_bar: OptionButton = null
var _status: Label = null
var _validation: RichTextLabel = null

func _ready() -> void:
	custom_minimum_size = Vector2(260, 400)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(vb)

	_mode_bar = OptionButton.new()
	for m in Mode.keys():
		_mode_bar.add_item(String(m).capitalize())
	_mode_bar.item_selected.connect(_on_mode_selected)
	vb.add_child(_mode_bar)

	_status = Label.new()
	_status.text = "No map loaded"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_status)

	_validation = RichTextLabel.new()
	_validation.custom_minimum_size = Vector2(0, 160)
	_validation.bbcode_enabled = true
	vb.add_child(_validation)

	var save_btn := Button.new()
	save_btn.text = "Save map"
	save_btn.pressed.connect(save_map)
	vb.add_child(save_btn)

	var play_btn := Button.new()
	play_btn.text = "Play this map"
	play_btn.pressed.connect(play_map)
	vb.add_child(play_btn)

func _on_mode_selected(idx: int) -> void:
	mode = idx as Mode

## True when a map is loaded and the plugin should own viewport input.
func is_editing() -> bool:
	return doc != null

func load_map(path: String) -> void:
	doc = MapDocument.load_from(path)
	if doc == null:
		_status.text = "Failed to load %s" % path
		return
	_status.text = "%s — %d buildings, %d points" % [doc.map_name, doc.buildings.size(), doc.points.size()]
	refresh_validation()

func save_map() -> void:
	if doc == null:
		return
	var err := doc.save()
	_status.text = "Saved %s" % doc.source_path if err == OK else "SAVE FAILED (%d)" % err

## Re-run the pure validator and surface its findings. Called after every mutation.
func refresh_validation() -> void:
	if doc == null or _validation == null:
		return
	var errs := MapValidator.check(_doc_dict())
	if errs.is_empty():
		_validation.text = "[color=green]No problems[/color]"
		return
	var lines := "[color=orange]%d problem(s):[/color]\n" % errs.size()
	for e in errs:
		lines += "• %s\n" % e
	_validation.text = lines

func _doc_dict() -> Dictionary:
	return {"world_half": doc.world_half, "buildings": doc.buildings, "roads": doc.roads,
		"points": doc.points, "bases": doc.bases}

## Launch the game on the saved map — the lit WYSIWYG check. Saves first: playing a stale file is a
## worse lie than not playing at all. Runs detached so the editor stays usable.
func play_map() -> void:
	if doc == null:
		return
	save_map()
	var map_id := doc.source_path.get_file().get_basename()
	var exe := OS.get_executable_path()
	OS.create_process(exe, ["--path", ProjectSettings.globalize_path("res://"), "--", "--map", map_id])

## --- Pure helpers. Static and document-only so the headless suite can test the tools' behaviour
## --- without a live EditorInterface. The click handlers below are thin wrappers over these.

## Intersect a ray with the horizontal plane y = plane_y. Returns {"hit": bool, "pos": Vector3}.
static func ray_to_ground(from: Vector3, dir: Vector3, plane_y: float) -> Dictionary:
	if absf(dir.y) < 0.0001:
		return {"hit": false, "pos": Vector3.ZERO}   # parallel to the plane
	var t := (plane_y - from.y) / dir.y
	if t < 0.0:
		return {"hit": false, "pos": Vector3.ZERO}   # plane is behind the ray
	return {"hit": true, "pos": from + dir * t}

## World position -> BuildGrid cell. Buildings snap; props do not.
static func snap_cell(world: Vector3) -> Vector3i:
	return Vector3i(int(floor(world.x / BuildGrid.CELL_SIZE)), 0, int(floor(world.z / BuildGrid.CELL_SIZE)))

## Place a building AND bake its world-AABB footprint. The footprint is not optional bookkeeping:
## MapValidator falls back to the single origin cell without it (so overlaps would go undetected),
## and Terrain.load_for_map uses it to flatten the FULL building pad instead of one cell — a building
## saved without it sits on a half-flattened foundation on sloped ground. map_gen bakes it for the
## same reasons; the editor must too.
static func doc_place_building(doc, prefab: String, cell: Vector3i, yaw: int) -> void:
	var b := {"prefab": prefab, "origin_cell": cell, "yaw": yaw}
	var fp := prefab_footprint(prefab, cell, yaw)
	if not fp.is_empty():
		b["footprint"] = fp
	doc.buildings.append(b)

## World AABB of `prefab` placed at `cell` with `yaw`. Derived from the prefab's piece offsets — the
## same extent maths as tools/map_gen.py::extent/footprint, which this must agree with or the editor
## and the generator will disagree about what overlaps.
static func prefab_footprint(prefab: String, cell: Vector3i, yaw: int) -> Dictionary:
	var path := "res://buildings/%s.json" % prefab
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or not data.has("pieces"):
		return {}
	var max_x := 0
	var max_z := 0
	for p in data["pieces"]:
		var off = p["offset"]
		max_x = maxi(max_x, int(off[0]))
		max_z = maxi(max_z, int(off[2]))
	# Piece offsets are cell indices, so the prefab spans (max+1) cells on each axis.
	var w := float(max_x + 1) * BuildGrid.CELL_SIZE
	var l := float(max_z + 1) * BuildGrid.CELL_SIZE
	# A 90/270 deg yaw swaps the footprint's axes (YAW_STEPS spans a full turn).
	var quarter := yaw % BuildGrid.YAW_STEPS
	var per_quarter := BuildGrid.YAW_STEPS / 4
	if per_quarter > 0 and (quarter / per_quarter) % 2 == 1:
		var t := w
		w = l
		l = t
	var mn := BuildGrid.cell_min(cell)
	return {"min_x": mn.x, "max_x": mn.x + w, "min_z": mn.z, "max_z": mn.z + l}

static func doc_erase_building(doc, index: int) -> void:
	if index >= 0 and index < doc.buildings.size():
		doc.buildings.remove_at(index)

static func doc_place_prop(doc, id: String, pos: Vector3, yaw: float, scale: float) -> void:
	doc.scenery.append({"id": id, "pos": pos, "yaw": yaw, "scale": scale})

## Append a control point to road `index`, creating the road if it does not exist yet.
static func doc_add_road_point(doc, index: int, pt: Vector2, width: float) -> void:
	while doc.roads.size() <= index:
		doc.roads.append({"spline": PackedVector2Array(), "width": width})
	var sp: PackedVector2Array = doc.roads[index]["spline"]
	sp.append(pt)
	doc.roads[index]["spline"] = sp
	doc.roads[index]["width"] = width

## Sculpt the document's heightmap. Heights are stored NORMALISED 0..1, so `strength` (metres) is
## converted through height_scale and the result is clamped — a stroke that pushed past 0..1 would
## be silently truncated by the encoder and the owner would sculpt terrain that does not save.
static func doc_sculpt(doc, center_xz: Vector2, radius: float, strength_m: float, mode: int) -> void:
	if doc.heights.is_empty() or doc.height_scale <= 0.0:
		return
	var norm_strength: float = strength_m / doc.height_scale
	TerrainBrush.apply(doc.heights, doc.cols, doc.rows, doc.sample_spacing,
		Vector2(-doc.world_half, -doc.world_half), center_xz, radius, norm_strength, mode as TerrainBrush.Mode)
	for i in doc.heights.size():
		doc.heights[i] = clampf(doc.heights[i], 0.0, 1.0)

static func doc_erase_prop(doc, index: int) -> void:
	if index >= 0 and index < doc.scenery.size():
		doc.scenery.remove_at(index)

## --- Markers (capture points + team bases). The dock's marker selector picks WHICH marker a click
## --- moves; `current_marker` is {"kind": "point"|"base", "index": int}.

## Move capture point `index` to `pos` (y is kept — objectives sit at the authored height).
static func doc_move_point(doc, index: int, pos: Vector3) -> void:
	if index >= 0 and index < doc.points.size():
		doc.points[index]["pos"] = Vector3(pos.x, doc.points[index]["pos"].y, pos.z)

static func doc_set_point_radius(doc, index: int, radius: float) -> void:
	if index >= 0 and index < doc.points.size():
		doc.points[index]["radius"] = maxf(radius, 0.1)

static func doc_move_base(doc, index: int, pos: Vector3) -> void:
	if index >= 0 and index < doc.bases.size():
		doc.bases[index]["pos"] = Vector3(pos.x, doc.bases[index]["pos"].y, pos.z)

## Append a new capture point. Ids are A, B, C… matching the existing maps' convention.
static func doc_add_point(doc, pos: Vector3, radius: float) -> void:
	var id := char(65 + doc.points.size()) if doc.points.size() < 26 else "P%d" % doc.points.size()
	doc.points.append({"id": id, "pos": pos, "radius": radius, "start_owner": -1})

## Route a viewport click to the active tool. Every mutation is wrapped in EditorUndoRedoManager so
## Ctrl+Z behaves exactly as the owner expects from the rest of the Godot editor.
func handle_viewport_input(camera: Camera3D, event: InputEvent) -> int:
	if doc == null or camera == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not (event is InputEventMouseButton) or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var from := camera.project_ray_origin(event.position)
	var dir := camera.project_ray_normal(event.position)
	var hit := ray_to_ground(from, dir, 0.0)
	if not bool(hit["hit"]):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var pos: Vector3 = hit["pos"]
	match mode:
		Mode.TERRAIN:
			_undo_sculpt(pos)
		Mode.BUILDING:
			_undo_place_building(snap_cell(pos))
		Mode.PROP:
			_undo_place_prop(pos)
		Mode.ROAD:
			_undo_add_road_point(Vector2(pos.x, pos.z))
		Mode.MARKER:
			_undo_move_marker(pos)
	refresh_validation()
	preview_dirty.emit()
	return EditorPlugin.AFTER_GUI_INPUT_STOP

signal preview_dirty

func _undo_place_building(cell: Vector3i) -> void:
	if undo_redo == null:
		doc_place_building(doc, current_prefab, cell, current_yaw)
		return
	# `doc.buildings.size()` is evaluated NOW, before the do runs — so it is the index the new
	# building will occupy, which is exactly what undo must erase. Do not "fix" this to size()-1.
	var new_index := doc.buildings.size()
	undo_redo.create_action("Place building")
	undo_redo.add_do_method(self, "doc_place_building", doc, current_prefab, cell, current_yaw)
	undo_redo.add_undo_method(self, "doc_erase_building", doc, new_index)
	undo_redo.commit_action()

## Move the selected marker to the click position.
func _undo_move_marker(pos: Vector3) -> void:
	var kind := String(current_marker.get("kind", "point"))
	var idx := int(current_marker.get("index", 0))
	var method := "doc_move_point" if kind == "point" else "doc_move_base"
	var list: Array = doc.points if kind == "point" else doc.bases
	if idx < 0 or idx >= list.size():
		return
	var old: Vector3 = list[idx]["pos"]
	if undo_redo == null:
		callv(method, [doc, idx, pos])
		return
	undo_redo.create_action("Move %s" % kind)
	undo_redo.add_do_method(self, method, doc, idx, pos)
	undo_redo.add_undo_method(self, method, doc, idx, old)
	undo_redo.commit_action()

func _undo_place_prop(pos: Vector3) -> void:
	if undo_redo == null:
		doc_place_prop(doc, current_prop, pos, randf() * TAU, 1.0)
		return
	undo_redo.create_action("Place prop")
	undo_redo.add_do_method(self, "doc_place_prop", doc, current_prop, pos, randf() * TAU, 1.0)
	undo_redo.add_undo_method(self, "doc_erase_prop", doc, doc.scenery.size())
	undo_redo.commit_action()

func _undo_add_road_point(pt: Vector2) -> void:
	doc_add_road_point(doc, current_road, pt, current_road_width)

## Sculpt strokes are continuous, so snapshotting the whole heightmap per click would be the
## simplest undo but also the heaviest (a 684x684 map is ~1.9 MB a stroke). Snapshot per STROKE:
## the plugin calls begin_sculpt_stroke on press and end_sculpt_stroke on release.
func _undo_sculpt(pos: Vector3) -> void:
	doc_sculpt(doc, Vector2(pos.x, pos.z), brush_radius, brush_strength, brush_mode)

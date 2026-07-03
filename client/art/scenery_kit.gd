class_name SceneryKit
extends Object
## Instantiates imported Broken Vector scenery GLBs by catalog id. Presentation-only (AGENTS.md §7).
## Categories: tree, rock, cliff, road, road_car, storage, vehicle_static, prop (vertex-colored; no palette).
## Models are exported Y-up with their base on y=0; map `scenery` entries place them at pos + yaw (+ optional scale).
## Map-wide `scenery_palette` sets default colorsheets; per-instance `palette` on a scenery entry overrides
## the map default for that prop's category (tree or rock).

const CATALOG_PATH := "res://data/scenery_catalog.json"

static var _catalog: SceneryCatalog

static func _cat() -> SceneryCatalog:
	if _catalog == null:
		_catalog = SceneryCatalog.load_file(CATALOG_PATH)
	return _catalog

## Build a scenery instance. `map_palette` is the map's scenery_palette ({tree, rock} names).
## `instance_palette` overrides the map default for this prop's category when non-empty.
static func build(scenery_id: String, map_palette: Dictionary = {}, instance_palette: String = "") -> Node3D:
	var path := _cat().path_for(scenery_id) if _cat() != null else ""
	if path.is_empty():
		push_warning("[SceneryKit] unknown id: %s" % scenery_id)
		return null
	var ps := load(path) as PackedScene
	if ps == null:
		push_warning("[SceneryKit] failed to load: %s" % path)
		return null
	var model := ps.instantiate() as Node3D
	if model == null:
		return null
	_apply_palette(model, scenery_id, map_palette, instance_palette)
	var wrapper := Node3D.new()
	wrapper.name = scenery_id
	wrapper.add_child(model)
	return wrapper

static func _resolve_palette_name(category: String, map_palette: Dictionary, instance_palette: String) -> String:
	var cat := _cat()
	if cat == null:
		return ""
	var chosen := instance_palette if not instance_palette.is_empty() else String(map_palette.get(category, ""))
	if chosen.is_empty():
		chosen = cat.default_palette_for(category)
	if chosen.is_empty():
		return ""
	if not cat.has_palette(category, chosen):
		push_warning("[SceneryKit] unknown %s palette '%s'; using default" % [category, chosen])
		chosen = cat.default_palette_for(category)
	return chosen

static func _apply_palette(root: Node3D, scenery_id: String, map_palette: Dictionary, instance_palette: String) -> void:
	var cat := _cat()
	if cat == null:
		return
	var category := cat.category_for(scenery_id)
	if category.is_empty():
		return
	var palette_name := _resolve_palette_name(category, map_palette, instance_palette)
	var tex_path := cat.palette_path_for(category, palette_name)
	if tex_path.is_empty():
		return
	var tex := load(tex_path) as Texture2D
	if tex == null:
		push_warning("[SceneryKit] failed to load palette texture: %s" % tex_path)
		return
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			_set_mesh_albedo(node as MeshInstance3D, tex)
		for child in node.get_children():
			stack.append(child)

static func _set_mesh_albedo(mi: MeshInstance3D, tex: Texture2D) -> void:
	var mesh: Mesh = mi.mesh
	if mesh == null:
		return
	for si in mesh.get_surface_count():
		var mat: Material = mi.get_surface_override_material(si)
		if mat == null:
			mat = mesh.surface_get_material(si)
		if mat == null:
			continue
		if mi.get_surface_override_material(si) == null:
			mat = mat.duplicate()
			mi.set_surface_override_material(si, mat)
		if mat is BaseMaterial3D:
			(mat as BaseMaterial3D).albedo_texture = tex

static func reset_catalog_for_tests() -> void:
	_catalog = null

## Headless-test helper: first albedo texture path on any mesh under `root`, or "".
static func albedo_texture_path(root: Node3D) -> String:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			var mesh: Mesh = mi.mesh
			if mesh != null:
				for si in mesh.get_surface_count():
					var mat: Material = mi.get_surface_override_material(si)
					if mat == null:
						mat = mesh.surface_get_material(si)
					if mat is BaseMaterial3D:
						var tex: Texture2D = (mat as BaseMaterial3D).albedo_texture
						if tex != null:
							return tex.resource_path
		for child in node.get_children():
			stack.append(child)
	return ""

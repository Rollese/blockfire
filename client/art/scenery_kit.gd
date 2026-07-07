class_name SceneryKit
extends Object
## Instantiates map scenery. TREES and ROCKS are generated procedurally by [TreeKit] / [RockKit]
## (BattleBit-style pixel-cutout frond foliage + faceted triplanar boulders) — routed by id prefix,
## no external mesh. Every other category (cliff / road / road_car / storage / vehicle_static / prop)
## loads its imported GLB + palette-texture as before. Presentation-only (AGENTS.md §7).
##
## Trees/rocks previously used flat GLBs whose UVs were dropped on export (rendered grey/pink), worked
## around with a procedural override material. That whole path is gone — the kits own the geometry AND
## the UVs, so the pixel textures map correctly.

const CATALOG_PATH := "res://data/scenery_catalog.json"

static var _catalog: SceneryCatalog

static func _cat() -> SceneryCatalog:
	if _catalog == null:
		_catalog = SceneryCatalog.load_file(CATALOG_PATH)
	return _catalog

## Build a scenery instance. `tree_*` / `rock_*` ids are generated procedurally, seeded by `seed` so each
## placement is deterministic but varied. All other ids load their catalog GLB. `map_palette` /
## `instance_palette` still tint the GLB categories; they are ignored for the procedural kinds.
static func build(scenery_id: String, map_palette: Dictionary = {}, instance_palette: String = "", seed: int = 0) -> Node3D:
	if scenery_id.begins_with("tree_"):
		return TreeKit.build(seed)
	if scenery_id.begins_with("rock_"):
		return RockKit.build(seed)

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
			var bm := mat as BaseMaterial3D
			# These GLBs ship their OWN baked colour-atlas with model-specific UVs. Keep the model's own
			# texture; only drop in the palette when the model shipped none. Force NEAREST either way:
			# these tiny colour atlases blur into muddy wrong colours under the default LINEAR filter.
			bm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			if bm.albedo_texture == null:
				bm.albedo_texture = tex

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

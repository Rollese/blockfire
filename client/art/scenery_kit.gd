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
	# The tree/rock GLBs import with NO usable UVs, so neither their own baked atlas nor a palette LUT
	# maps — they render a flat dark/grey/pink colour on every GPU (2026-07-06 playtest). Override with a
	# procedural material instead: a local-height gradient (brown trunk -> green canopy) for trees, and a
	# mottled stone shader for rocks. Deterministic, GPU-independent, and actually looks like nature.
	if category == "tree":
		_apply_override(root, _tree_material())
		return
	if category == "rock":
		_apply_override(root, _rock_material())
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

static var _tree_mat: ShaderMaterial
static var _rock_mat: ShaderMaterial

static func _apply_override(root: Node3D, mat: Material) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			(node as MeshInstance3D).material_override = mat
		for child in node.get_children():
			stack.append(child)

## Brown trunk near the base, green canopy above (local model Y — scale-independent), with a little
## per-cell colour variation so the foliage isn't flat. Trees import with no UVs, so this replaces the
## unusable baked texture.
static func _tree_material() -> ShaderMaterial:
	if _tree_mat == null:
		var sh := Shader.new()
		sh.code = """
shader_type spatial;
render_mode specular_disabled;
varying vec3 lv;
varying vec3 lw;
void vertex() { lv = VERTEX; lw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float h3(vec3 p) { return fract(sin(dot(floor(p), vec3(12.9, 78.2, 37.7))) * 43758.5); }
void fragment() {
	float t = smoothstep(1.2, 3.2, lv.y);            // 0 = trunk, 1 = canopy
	vec3 trunk = vec3(0.28, 0.19, 0.11);
	vec3 leaf = mix(vec3(0.12, 0.29, 0.11), vec3(0.24, 0.44, 0.18), h3(lw * 1.6));
	ALBEDO = mix(trunk, leaf, t);
	ROUGHNESS = 1.0;
}
"""
		_tree_mat = ShaderMaterial.new()
		_tree_mat.shader = sh
	return _tree_mat

## Mottled grey/tan stone with fake AO (undersides darker) so rocks read as textured, not flat grey.
static func _rock_material() -> ShaderMaterial:
	if _rock_mat == null:
		var sh := Shader.new()
		sh.code = """
shader_type spatial;
render_mode specular_disabled;
varying vec3 lw;
varying vec3 wn;
void vertex() { lw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz); }
float hh(vec2 p) { p = fract(p * vec2(123.3, 345.4)); p += dot(p, p + 34.3); return fract(p.x * p.y); }
float vn(vec2 p) { vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hh(i), hh(i + vec2(1,0)), u.x), mix(hh(i + vec2(0,1)), hh(i + vec2(1,1)), u.x), u.y); }
void fragment() {
	float n = vn(lw.xz * 0.7) * 0.5 + vn(lw.xz * 3.1) * 0.5;
	vec3 base = mix(vec3(0.29, 0.29, 0.31), vec3(0.52, 0.49, 0.45), n);
	base *= (0.68 + 0.32 * clamp(wn.y * 0.5 + 0.5, 0.0, 1.0));   // tops lighter, undersides darker
	ALBEDO = base;
	ROUGHNESS = 1.0;
}
"""
		_rock_mat = ShaderMaterial.new()
		_rock_mat.shader = sh
	return _rock_mat

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
			# These GLBs ship their OWN baked colour-atlas texture (green foliage + brown trunk) with
			# model-specific UVs. The old code REPLACED it with a shared 16x16 palette LUT whose layout
			# does NOT match those UVs -> garbage colours (grey/pink trees). Keep the model's own texture;
			# only drop in the palette when the model shipped none. Force NEAREST either way: these tiny
			# colour atlases blur into muddy wrong colours under the default LINEAR filter.
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

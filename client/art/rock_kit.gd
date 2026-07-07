class_name RockKit
extends Object
## PROTOTYPE — self-generated low-poly boulder: a faceted (flat-shaded) mesh built by noise-displacing a
## coarse sphere, wrapped in a TRIPLANAR pixel-noise stone material. Triplanar projects the detail texture
## along the three world axes, so it needs NO UVs at all — which sidesteps exactly the problem that broke
## the imported rock GLBs (their UVs were dropped on export). The "virtually random pixelated noise" detail
## you spotted on the BattleBit boulder is a small tiling noise texture sampled with NEAREST filtering.
## Deterministic, GPU-independent, presentation-only (AGENTS.md §7).

const DETAIL := 64            # stone detail texture resolution
const COBBLE := 96           # cobble ground-patch texture resolution
static var _stone_mat: ShaderMaterial
static var _detail_tex: ImageTexture
static var _cobble_mat: StandardMaterial3D

## A flat rocky GROUND PATCH — the "rock you stand on" in the reference is a flat pebble/cobble plane
## lying flush on the terrain, NOT a 3D boulder. Rounded light pebbles in dark mortar, nearest-filtered.
## `size` = patch width in metres. Sits just above y=0 to avoid z-fighting the ground.
static func build_patch(seed: int = 0, size: float = 4.0) -> Node3D:
	var root := Node3D.new()
	root.name = "rock_patch"
	var pm := PlaneMesh.new()
	pm.size = Vector2(size, size)
	var mi := MeshInstance3D.new()
	mi.name = "patch"
	mi.mesh = pm
	mi.position = Vector3(0, 0.02, 0)
	mi.material_override = _cobble_material()
	root.add_child(mi)
	return root

## Build one boulder. `seed` makes the lumpy silhouette deterministic. `size` scales it (metres, tall axis).
static func build(seed: int = 0, size: float = 1.6) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var root := Node3D.new()
	root.name = "rock"

	# Non-uniform scale so it reads as a boulder, not a ball.
	var sc := Vector3(rng.randf_range(0.8, 1.3), rng.randf_range(0.55, 0.9), rng.randf_range(0.8, 1.3))
	var base := SphereMesh.new()
	base.radius = 1.0
	base.height = 2.0
	base.radial_segments = 7      # low-poly → chunky facets
	base.rings = 5
	var faces := base.get_faces()   # deindexed triangle soup (PackedVector3Array)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lo := Vector3(INF, INF, INF)
	var displaced: Array = []
	for v in faces:
		var nv := _displace(v, seed) * sc
		displaced.append(nv)
		lo.y = minf(lo.y, nv.y)
	for nv in displaced:
		st.add_vertex(nv)
	st.generate_normals()          # unindexed → per-face normals = flat/faceted shading
	var mesh := st.commit()

	var s := size / 2.0                  # base sphere spans ~2 units tall before this uniform scale
	var mi := MeshInstance3D.new()
	mi.name = "boulder"
	mi.mesh = mesh
	mi.material_override = _stone_material()
	mi.scale = Vector3.ONE * s
	mi.position = Vector3(0, -lo.y * s, 0)   # seat the lowest (scaled) vertex on y=0
	root.add_child(mi)
	return root

## Displace a unit-sphere vertex outward by low- + high-frequency deterministic noise, so duplicated
## (shared) vertices from get_faces() move IDENTICALLY (hash keyed on the rounded original position) and
## the mesh stays watertight — no cracked facets.
static func _displace(v: Vector3, seed: int) -> Vector3:
	var dir := v.normalized()
	if dir.length() < 0.001:
		dir = Vector3.UP
	var q := (v * 4.0).round()   # quantise so identical source verts hash the same
	var lump := _hash3(q, seed) - 0.5                    # coarse bumps
	var fine := _hash3(q * 2.0, seed + 11) - 0.5         # finer detail
	var r := 1.0 + lump * 0.42 + fine * 0.16
	return dir * r

# --- material ---------------------------------------------------------------

static func _stone_material() -> ShaderMaterial:
	if _stone_mat == null:
		var sh := Shader.new()
		sh.code = """
shader_type spatial;
render_mode specular_disabled;
uniform sampler2D detail : filter_nearest, repeat_enable;   // NEAREST = crunchy pixels; triplanar = no UVs
uniform float tscale = 0.6;
varying vec3 wpos;
varying vec3 wn;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec3 bw = abs(normalize(wn));
	bw /= (bw.x + bw.y + bw.z);                              // triplanar blend weights
	float d = texture(detail, wpos.zy * tscale).r * bw.x
		    + texture(detail, wpos.xz * tscale).r * bw.y
		    + texture(detail, wpos.xy * tscale).r * bw.z;
	vec3 base = mix(vec3(0.27, 0.27, 0.30), vec3(0.55, 0.51, 0.46), d);
	base *= (0.62 + 0.38 * clamp(wn.y * 0.5 + 0.5, 0.0, 1.0));  // fake AO: tops lit, undersides dark
	ALBEDO = base;
	ROUGHNESS = 1.0;
}
"""
		_stone_mat = ShaderMaterial.new()
		_stone_mat.shader = sh
		_stone_mat.set_shader_parameter("detail", _detail_texture())
	return _stone_mat

static func _cobble_material() -> StandardMaterial3D:
	if _cobble_mat == null:
		_cobble_mat = StandardMaterial3D.new()
		_cobble_mat.albedo_texture = _cobble_texture()
		_cobble_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		_cobble_mat.roughness = 1.0
		_cobble_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _cobble_mat

## Rounded pebbles in dark mortar via a jittered grid of feature points (cellular / Worley-ish): a pixel
## near a feature point is a light tan pebble (value varies per cell), between points is dark mortar.
static func _cobble_texture() -> ImageTexture:
	var img := Image.create(COBBLE, COBBLE, false, Image.FORMAT_RGB8)
	var cells := 6                       # pebbles across the tile
	var step := float(COBBLE) / cells
	for y in COBBLE:
		for x in COBBLE:
			var gx := int(floor(x / step))
			var gy := int(floor(y / step))
			var best := 1e9
			var best_id := 0
			for oy in range(-1, 2):
				for ox in range(-1, 2):
					var cx := posmod(gx + ox, cells)
					var cy := posmod(gy + oy, cells)
					# jittered feature point inside the (wrapped) neighbour cell
					var fx := (gx + ox + 0.5 + (_hash2(cx, cy, 1) - 0.5) * 0.8) * step
					var fy := (gy + oy + 0.5 + (_hash2(cx, cy, 2) - 0.5) * 0.8) * step
					var d := Vector2(x, y).distance_to(Vector2(fx, fy))
					if d < best:
						best = d
						best_id = cx * 97 + cy
			var pebble := 1.0 - smoothstep(step * 0.28, step * 0.5, best)   # 1 at pebble centre → 0 mortar
			var tone := 0.72 + _hash2(best_id, best_id, 3) * 0.22
			var mortar := Color(0.30, 0.26, 0.22)
			var stone := Color(0.66 * tone, 0.58 * tone, 0.48 * tone)
			img.set_pixel(x, y, mortar.lerp(stone, pebble))
	return ImageTexture.create_from_image(img)

## Tiling grayscale value-noise — the "random pixelated" stone detail. Small + nearest-sampled in-shader.
static func _detail_texture() -> ImageTexture:
	if _detail_tex == null:
		var img := Image.create(DETAIL, DETAIL, false, Image.FORMAT_RGB8)
		for y in DETAIL:
			for x in DETAIL:
				# blend two octaves of tiling value noise for a bit of structure, keep it crunchy
				var n := _vnoise(x, y, 8) * 0.6 + _vnoise(x, y, 16) * 0.4
				img.set_pixel(x, y, Color(n, n, n))
		_detail_tex = ImageTexture.create_from_image(img)
	return _detail_tex

## Tileable value noise at grid frequency `freq` over the DETAIL texture (wraps cleanly).
static func _vnoise(x: int, y: int, freq: int) -> float:
	var fx := float(x) / float(DETAIL) * freq
	var fy := float(y) / float(DETAIL) * freq
	var ix := int(floor(fx))
	var iy := int(floor(fy))
	var tx := fx - ix
	var ty := fy - iy
	var ux := tx * tx * (3.0 - 2.0 * tx)
	var uy := ty * ty * (3.0 - 2.0 * ty)
	var a := _cell(ix, iy, freq)
	var b := _cell(ix + 1, iy, freq)
	var c := _cell(ix, iy + 1, freq)
	var d := _cell(ix + 1, iy + 1, freq)
	return lerpf(lerpf(a, b, ux), lerpf(c, d, ux), uy)

static func _cell(ix: int, iy: int, freq: int) -> float:
	# wrap the lattice so the tile is seamless
	return _hash2(posmod(ix, freq), posmod(iy, freq), freq)

static func _hash2(x: int, y: int, s: int) -> float:
	var h := int(x) * 374761393 + int(y) * 668265263 + int(s) * 2147483647
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFF) / 65535.0

static func _hash3(p: Vector3, s: int) -> float:
	return _hash2(int(p.x) * 92837 + int(p.z) * 689287, int(p.y), s)

static func reset_cache_for_tests() -> void:
	_stone_mat = null
	_detail_tex = null
	_cobble_mat = null

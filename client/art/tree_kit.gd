class_name TreeKit
extends Object
## PROTOTYPE v2 — self-generated BattleBit-style tree, corrected against reference screenshots:
##   * a BRANCHING grey trunk (trunk splits into several big limbs you can see through the canopy)
##   * a canopy of large, elongated FROND planes (not round bush-puffs) radiating + drooping from the limbs
##   * each frond is an alpha-CUTOUT quad masked by an in-engine PIXEL leaf-spray texture (nearest-filtered)
##   * yellow-lime / olive / desaturated-grey leaf palette, chunky low-res pixels
## WE own the geometry + UVs (unlike the imported GLBs whose UVs were dropped). Presentation-only (§7).
##
## Ship-path perf notes (this prototype builds discrete nodes for clarity): fronds use ALPHA_SCISSOR
## (alpha-test, never blend → no transparency sorting/overdraw at forest density, casts a cutout shadow);
## pixelated look = small source texture + TEXTURE_FILTER_NEAREST; at scale, batch into MultiMesh.

const FROND_TEX_W := 96        # elongated leaf-spray source (2:1), small on purpose → chunky pixels
const FROND_TEX_H := 48
const LEAF_VARIANTS := 4

static var _frond_mats: Array = []
static var _bark_mat: StandardMaterial3D

## Build one tree. `seed` makes trunk/limb/frond layout deterministic. `scale` sizes it (default ~9 m).
static func build(seed: int = 0, scale: float = 1.0) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var root := Node3D.new()
	root.name = "tree"

	var trunk_h := rng.randf_range(5.0, 7.0) * scale       # reference height for fork placement
	var trunk_r := rng.randf_range(0.28, 0.40) * scale

	# Decide the limbs first, so the trunk can END just above the highest fork (not run on as a bare pole).
	var n_limbs := rng.randi_range(3, 5)
	var base_yaw := rng.randf_range(0.0, TAU)
	var limbs: Array = []
	var top_fork := 0.0
	for i in n_limbs:
		var yaw := base_yaw + TAU * float(i) / n_limbs + rng.randf_range(-0.3, 0.3)
		var tilt := rng.randf_range(0.55, 0.95)                     # radians from vertical
		var fork_at := rng.randf_range(0.42, 0.80) * trunk_h
		var dir := Vector3(sin(tilt) * cos(yaw), cos(tilt), sin(tilt) * sin(yaw)).normalized()
		var length := rng.randf_range(2.4, 3.8) * scale
		limbs.append({"fork": fork_at, "dir": dir, "len": length})
		top_fork = maxf(top_fork, fork_at)
	var trunk_top := top_fork + 0.35 * scale                        # short stub above the last branch, tapering in

	var frond_i := 0
	root.add_child(_limb_mesh("trunk", Vector3.ZERO, Vector3.UP, trunk_top, trunk_r, trunk_r * 0.45))

	for i in limbs.size():
		var L: Dictionary = limbs[i]
		var dir: Vector3 = L["dir"]
		var length: float = L["len"]
		var start := Vector3(0, L["fork"], 0)
		root.add_child(_limb_mesh("limb_%d" % i, start, dir, length, trunk_r * 0.55, trunk_r * 0.26))
		var tip := start + dir * length
		# frond count scales with limb length so long limbs don't read as bare
		var per := clampi(int(round(length / scale * 2.8)) + rng.randi_range(1, 2), 7, 12)
		for j in per:
			var t := rng.randf_range(0.35, 1.0)                     # spread along the outer 2/3 of the limb
			var at := start.lerp(tip, t)
			# jitter each frond's spray direction independently → no stamped-in-a-row duplicates
			root.add_child(_frond(frond_i, at, _jitter_dir(dir, rng), scale, rng)); frond_i += 1

	# Crown: fronds clustered at the trunk top so the silhouette has a filled crown.
	var top := Vector3(0, trunk_top, 0)
	for k in rng.randi_range(4, 6):
		var cdir := Vector3(rng.randfn() * 0.7, 1.0, rng.randfn() * 0.7).normalized()
		root.add_child(_frond(frond_i, top + Vector3(0, rng.randf_range(0.0, 0.4) * scale, 0), cdir, scale, rng))
		frond_i += 1
	return root

## Randomly deflect a limb direction (yaw around vertical + tilt) so fronds fan out in varied directions
## rather than all inheriting the limb's exact orientation.
static func _jitter_dir(dir: Vector3, rng: RandomNumberGenerator) -> Vector3:
	var d := dir.rotated(Vector3.UP, rng.randf_range(-1.1, 1.1))
	var perp := Vector3.UP.cross(d)
	if perp.length() > 0.001:
		d = d.rotated(perp.normalized(), rng.randf_range(-0.55, 0.55))
	return d.normalized()

# --- geometry ---------------------------------------------------------------

## A tapered cylinder from `base` along unit `dir`, length `len`, radii bottom→top. Grey bark.
static func _limb_mesh(nm: String, base: Vector3, dir: Vector3, len: float, r0: float, r1: float) -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.bottom_radius = r0
	cyl.top_radius = r1
	cyl.height = len
	cyl.radial_segments = 6
	cyl.rings = 1
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = cyl
	mi.material_override = _bark_material()
	mi.transform.basis = _basis_from_up(dir)     # cylinder axis (+Y) → dir
	mi.position = base + dir * (len * 0.5)
	return mi

## A large elongated leaf-spray plane. Its broad face points outward-and-up from the branch, its long
## axis runs tangentially and droops — so it reads as a frond fanning out (visible from the side, not
## edge-on). `dir` is the parent limb's direction.
static func _frond(idx: int, pos: Vector3, dir: Vector3, scale: float, rng: RandomNumberGenerator) -> MeshInstance3D:
	var outward := Vector3(dir.x, 0, dir.z)
	if outward.length() < 0.05:
		outward = Vector3(rng.randfn(), 0, rng.randfn())     # near-vertical limb → pick a horizontal spray dir
	outward = outward.normalized()
	var up := Vector3.UP
	# per-frond mix of out-vs-up so neighbouring fronds don't share a face angle
	var normal := (outward * rng.randf_range(0.4, 0.65) + up * rng.randf_range(0.4, 0.65)).normalized()
	var width_axis := up.cross(outward).normalized()          # tangential (the long side)
	var long_axis := normal.cross(width_axis).normalized()    # up/out, droops at the far end
	# QuadMesh lies in local XY with +Z normal: map X→width_axis, Y→long_axis, Z→normal.
	var basis := Basis(width_axis, long_axis, normal)
	basis = basis.rotated(normal, rng.randf_range(-0.9, 0.9))  # wide per-frond roll variation

	var q := QuadMesh.new()
	q.size = Vector2(rng.randf_range(2.6, 3.6) * scale, rng.randf_range(1.6, 2.4) * scale)
	var mi := MeshInstance3D.new()
	mi.name = "frond_%d" % idx
	mi.mesh = q
	mi.transform.basis = basis
	mi.position = pos + outward * (q.size.x * 0.32)           # push the spray outboard of the branch
	mi.material_override = _frond_material(rng.randi_range(0, LEAF_VARIANTS - 1))
	return mi

static func _basis_from_up(up: Vector3) -> Basis:
	var u := up.normalized()
	var ref := Vector3.RIGHT if absf(u.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := ref.cross(u).normalized()
	var z := x.cross(u).normalized()
	return Basis(x, u, z)

# --- materials --------------------------------------------------------------

static func _bark_material() -> StandardMaterial3D:
	if _bark_mat == null:
		_bark_mat = StandardMaterial3D.new()
		_bark_mat.albedo_texture = _bark_texture()
		_bark_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		_bark_mat.uv1_scale = Vector3(2.0, 4.0, 1.0)
		_bark_mat.roughness = 1.0
		_bark_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _bark_mat

static func _frond_material(variant: int) -> StandardMaterial3D:
	if _frond_mats.is_empty():
		for v in LEAF_VARIANTS:
			var m := StandardMaterial3D.new()
			m.albedo_texture = _frond_texture(v)
			m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST      # pixelated-foliage lever
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR    # CUTOUT, not blend
			m.alpha_scissor_threshold = 0.5
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.roughness = 1.0
			m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
			_frond_mats.append(m)
	return _frond_mats[variant]

# --- procedural textures ----------------------------------------------------

## Elongated leaf-spray (compound leaf): leaflet blobs scattered in a tapering band along a central
## rachis, tip at the right. Yellow-lime / olive / desaturated-grey, ragged pixel edges, alpha cutout.
static func _frond_texture(variant: int) -> ImageTexture:
	var img := Image.create(FROND_TEX_W, FROND_TEX_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 2000 + variant
	var mid := FROND_TEX_H * 0.5
	# leaflet blobs, alternating above/below the rachis, radius + spread tapering toward the tip
	var blobs: Array = []
	var n := rng.randi_range(16, 22)
	for k in n:
		var t := float(k) / float(n - 1)                      # 0 base → 1 tip
		var x := lerpf(0.08, 0.95, t) * FROND_TEX_W
		var side := 1.0 if (k % 2 == 0) else -1.0
		var spread := lerpf(0.34, 0.06, t) * FROND_TEX_H
		var y := mid + side * spread * rng.randf_range(0.5, 1.0)
		blobs.append({"c": Vector2(x, y), "r": lerpf(0.20, 0.06, t) * FROND_TEX_H, "tone": rng.randf()})
	# palette
	var lime := Color(0.62, 0.70, 0.22)
	var olive := Color(0.34, 0.44, 0.15)
	var grey := Color(0.50, 0.54, 0.42)
	for py in FROND_TEX_H:
		for px in FROND_TEX_W:
			var p := Vector2(px, py)
			var cover := 0.0
			var tone := 0.5
			for b in blobs:
				var d: float = p.distance_to(b["c"]) / b["r"]
				var c := 1.0 - d
				if c > cover:
					cover = c
					tone = b["tone"]
			# rachis line so leaflets read as one frond
			if absf(py - mid) < 1.2 and px > 0.06 * FROND_TEX_W and px < 0.96 * FROND_TEX_W:
				cover = maxf(cover, 0.8)
			var jitter := _hash2(px, py, variant) * 0.4         # ragged pixel silhouette
			if cover + jitter <= 0.5:
				continue
			var shade := _hash2(px * 2, py * 2, variant + 5)
			var col := lime.lerp(olive, tone) if shade > 0.28 else grey
			col = col.lerp(olive, _hash2(px, py * 3, variant + 9) * 0.3)   # per-pixel value break-up
			img.set_pixel(px, py, Color(col.r, col.g, col.b, 1.0))
	return ImageTexture.create_from_image(img)

## Grey bark: vertical facet streaks + speckle.
static func _bark_texture() -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			var streak := 0.12 * sin(float(x) * 1.4 + _hash2(x, 0, 3) * 4.0)
			var v := 0.44 + streak + (_hash2(x, y, 5) - 0.5) * 0.12
			img.set_pixel(x, y, Color(v, v * 0.96, v * 0.88))    # slightly warm grey
	return ImageTexture.create_from_image(img)

static func _hash2(x: int, y: int, s: int) -> float:
	var h := int(x) * 374761393 + int(y) * 668265263 + int(s) * 2147483647
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFF) / 65535.0

static func reset_cache_for_tests() -> void:
	_frond_mats = []
	_bark_mat = null

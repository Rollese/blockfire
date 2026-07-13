class_name GrappleRope
extends Node3D
## Client-only cosmetic rope: a verlet chain pinned at the top anchor, sways with gravity + a bit of
## wind, rendered as a low-poly extruded TUBE (real triangle geometry, shaded). Decoupled from the
## straight gameplay climb line — it only needs to look right. Perf-guarded: sim only when near +
## on-screen, else a static straight line. Either way the tube is drawn thick (never a 1px GPU line).

const SEGMENTS := 10
const GRAVITY := Vector3(0, -12.0, 0)
const DAMP := 0.94
const WIND := 0.6
const SIM_RANGE := 38.0     # beyond this, draw a static straight line (no sim)
const CONSTRAINT_ITERS := 6
const RADIUS := 0.045       # tube radius (m) — thick enough to read at range
const TUBE_SIDES := 6       # radial segments per ring; low-poly, rebuilt per frame

var _top: Vector3
var _bottom: Vector3
var _pts: PackedVector3Array
var _prev: PackedVector3Array
var _rest: float
var _mesh_inst: MeshInstance3D
var _mesh := ImmediateMesh.new()
var _mat := StandardMaterial3D.new()
var _t := 0.0

func setup(top: Vector3, bottom: Vector3) -> void:
	_top = top
	_bottom = bottom
	_rest = (top - bottom).length() / float(SEGMENTS)
	_pts = PackedVector3Array()
	_prev = PackedVector3Array()
	for i in range(SEGMENTS + 1):
		var p := top.lerp(bottom, float(i) / float(SEGMENTS))
		_pts.append(p)
		_prev.append(p)
	_mat.albedo_color = Color(0.15, 0.12, 0.09)
	_mat.roughness = 1.0
	# Tube carries no vertex colours (only normals), so albedo_color must drive the colour directly —
	# otherwise vertex_color_use_as_albedo would tint by the default white vertex colour.
	_mat.vertex_color_use_as_albedo = false
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.mesh = _mesh
	_mesh_inst.material_override = _mat
	add_child(_mesh_inst)

func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var near := cam != null and cam.global_position.distance_to(_top) <= SIM_RANGE
	if near:
		_step(delta)
	else:
		for i in range(_pts.size()):
			_pts[i] = _top.lerp(_bottom, float(i) / float(SEGMENTS))
	_redraw()

func _step(delta: float) -> void:
	_t += delta
	var wind := Vector3(sin(_t * 1.3) * WIND, 0.0, cos(_t * 0.9) * WIND)
	for i in range(1, _pts.size()):   # i=0 pinned at top
		var cur := _pts[i]
		var vel := (cur - _prev[i]) * DAMP
		_prev[i] = cur
		_pts[i] = cur + vel + (GRAVITY + wind) * delta * delta
	for _it in range(CONSTRAINT_ITERS):
		_pts[0] = _top
		for i in range(1, _pts.size()):
			var d := _pts[i] - _pts[i - 1]
			var l := d.length()
			if l > 0.0001:
				var corr := d * (1.0 - _rest / l)
				_pts[i] -= corr * (1.0 if i == _pts.size() - 1 else 0.5)
				if i > 1:
					_pts[i - 1] += corr * 0.5

func _redraw() -> void:
	_mesh.clear_surfaces()
	# Vertices in local space (the MeshInstance is a child) — to_local is a rigid transform, so
	# building the tube frames from these local directions is equivalent to world space.
	var local := PackedVector3Array()
	for p in _pts:
		local.append(to_local(p))
	var geo := _tube_geometry(local, RADIUS, TUBE_SIDES)
	var verts: PackedVector3Array = geo["verts"]
	if verts.is_empty():
		return
	var normals: PackedVector3Array = geo["normals"]
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(verts.size()):
		_mesh.surface_set_normal(normals[i])
		_mesh.surface_add_vertex(verts[i])
	_mesh.surface_end()


# --- Pure tube geometry (static, SceneTree-free — unit tested) --------------------------------

## Orthonormal frame perpendicular to `dir`: returns [u, v] spanning the ring plane. The rope hangs
## mostly vertical, so we pick UP as the reference and fall back to RIGHT when the segment is near
## vertical (avoiding a degenerate cross). The reference stays constant, so the frame doesn't twist
## between adjacent near-vertical rings.
static func _frame(dir: Vector3) -> Array:
	var d := dir.normalized()
	if d.length() < 0.0001:
		d = Vector3.UP
	var ref := Vector3.UP
	if absf(d.dot(ref)) > 0.99:
		ref = Vector3.RIGHT
	var u := d.cross(ref).normalized()
	var v := d.cross(u).normalized()
	return [u, v]

## `sides` points evenly around `center` in the plane spanned by (u, v), each at `radius`.
static func _ring_points(center: Vector3, u: Vector3, v: Vector3, radius: float, sides: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in range(sides):
		var a := TAU * float(s) / float(sides)
		out.append(center + (u * cos(a) + v * sin(a)) * radius)
	return out

## Extruded triangle-soup tube around the polyline `pts` for a PRIMITIVE_TRIANGLES surface.
## Returns {"verts": PackedVector3Array, "normals": PackedVector3Array} (one outward unit normal per
## vertex). Vertex count is (N-1) * sides * 6. Empty when there are <2 points or sides<3.
static func _tube_geometry(pts: PackedVector3Array, radius: float, sides: int) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var n := pts.size()
	if n < 2 or sides < 3:
		return {"verts": verts, "normals": normals}
	# One ring (positions + outward normals) per polyline point, oriented by the local tangent.
	var rings: Array = []
	var rings_n: Array = []
	for i in range(n):
		var dir: Vector3
		if i == 0:
			dir = pts[1] - pts[0]
		elif i == n - 1:
			dir = pts[i] - pts[i - 1]
		else:
			dir = pts[i + 1] - pts[i - 1]   # averaged tangent smooths the seam between segments
		var f := _frame(dir)
		var u: Vector3 = f[0]
		var v: Vector3 = f[1]
		var ring := PackedVector3Array()
		var rn := PackedVector3Array()
		for s in range(sides):
			var a := TAU * float(s) / float(sides)
			var off := (u * cos(a) + v * sin(a))   # already unit length (u, v orthonormal)
			ring.append(pts[i] + off * radius)
			rn.append(off.normalized())
		rings.append(ring)
		rings_n.append(rn)
	# Stitch each adjacent ring pair into `sides` quads (two triangles apiece), wound outward.
	for i in range(n - 1):
		var r0: PackedVector3Array = rings[i]
		var r1: PackedVector3Array = rings[i + 1]
		var n0: PackedVector3Array = rings_n[i]
		var n1: PackedVector3Array = rings_n[i + 1]
		for s in range(sides):
			var s2 := (s + 1) % sides
			verts.append(r0[s]);  normals.append(n0[s])
			verts.append(r1[s]);  normals.append(n1[s])
			verts.append(r1[s2]); normals.append(n1[s2])
			verts.append(r0[s]);  normals.append(n0[s])
			verts.append(r1[s2]); normals.append(n1[s2])
			verts.append(r0[s2]); normals.append(n0[s2])
	return {"verts": verts, "normals": normals}

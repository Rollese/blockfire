class_name GrappleRope
extends Node3D
## Client-only cosmetic rope: a verlet chain pinned at the top anchor, sways with gravity + a bit of
## wind, rendered as an ImmediateMesh line. Decoupled from the straight gameplay climb line — it only
## needs to look right. Perf-guarded: sim only when near + on-screen, else a static straight line.

const SEGMENTS := 10
const GRAVITY := Vector3(0, -12.0, 0)
const DAMP := 0.94
const WIND := 0.6
const SIM_RANGE := 38.0     # beyond this, draw a static straight line (no sim)
const CONSTRAINT_ITERS := 6

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
	_mat.vertex_color_use_as_albedo = true
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
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in _pts:
		_mesh.surface_add_vertex(to_local(p))
	_mesh.surface_end()

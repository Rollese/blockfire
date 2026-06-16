class_name WorldRenderer
extends Node3D
## Presentation-only renderer. Reads MapDef + WorldView + Prediction each frame and draws
## placeholder primitives. Contains NO gameplay or authority logic (AGENTS.md §7, ADR-0005).
## P2 can swap meshes by changing _make_entity_mesh() / _make_ground_mesh() etc. without
## touching netcode or calling code.

# -- team colours (placeholder tint) ------------------------------------------
const TEAM_COLOR := [Color(0.2, 0.5, 1.0), Color(1.0, 0.3, 0.2)]  # [team0=blue, team1=red]
const NEUTRAL_COLOR := Color(0.6, 0.6, 0.6)

# -- viewmodel placeholder dimensions -----------------------------------------
const VM_SIZE := Vector3(0.08, 0.08, 0.35)
const VM_OFFSET := Vector3(0.15, -0.12, -0.40)   # right / down / forward in camera space

# -- pool state ---------------------------------------------------------------
var _camera: Camera3D = null

# active entity nodes: id(int) -> MeshInstance3D
var _active: Dictionary = {}
# free list for recycled entity MeshInstance3D nodes
var _free_list: Array = []

# viewmodel box (optional placeholder)
var _viewmodel: MeshInstance3D = null


# =============================================================================
#  Public interface
# =============================================================================

## Build static world geometry once. Call before any update().
func setup(map: MapDef, camera: Camera3D) -> void:
	_camera = camera

	# Ground plane
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	var side := map.world_half * 2.0
	plane.size = Vector2(side, side)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.25, 0.35, 0.20)   # muted green
	gmat.roughness = 1.0
	ground.material_override = gmat
	add_child(ground)

	# Capture point markers — tinted cylinders
	for pt: Dictionary in map.points:
		var pt_pos: Vector3 = pt["pos"] as Vector3
		var pt_radius: float = pt["radius"] as float
		var marker := _make_cylinder_marker(pt_radius * 0.5, 0.4, NEUTRAL_COLOR)
		marker.position = Vector3(pt_pos.x, 0.2, pt_pos.z)
		add_child(marker)

	# Base markers — team-coloured larger cylinders
	for b: Dictionary in map.bases:
		var b_team: int = b["team"] as int
		var b_pos: Vector3 = b["pos"] as Vector3
		var b_radius: float = b["radius"] as float
		var col: Color = TEAM_COLOR[b_team] if b_team < TEAM_COLOR.size() else NEUTRAL_COLOR
		var base_marker := _make_cylinder_marker(b_radius * 0.4, 0.8, col)
		base_marker.position = Vector3(b_pos.x, 0.4, b_pos.z)
		add_child(base_marker)

	# Viewmodel placeholder (parented to camera so it moves with it)
	_viewmodel = _make_box_mesh(VM_SIZE, Color(0.5, 0.5, 0.5))
	_viewmodel.position = VM_OFFSET
	# NOTE: we parent it to camera later in _apply_camera() to keep transforms clean.
	# For now it is not added; client_main can add it after setup() if desired.
	# Kept as an optional hook — Task 25 can wire it.


## Per-frame update. Safe to call with null world_view or predictor (early-returns).
func update(world_view: WorldView, predictor: Prediction, now: float, fov: float) -> void:
	if world_view == null or predictor == null:
		return

	# 1. Entity pool update
	var remotes: Dictionary = world_view.remotes_at(now)
	_sync_entity_pool(remotes)

	# 2. Camera from prediction
	_apply_camera(predictor, fov)


# =============================================================================
#  Entity pool helpers
# =============================================================================

func _sync_entity_pool(remotes: Dictionary) -> void:
	# Release nodes for ids that are gone or dead
	var to_release: Array = []
	for id: int in _active:
		if not remotes.has(id):
			to_release.append(id)
		else:
			var es: EntityState = remotes[id] as EntityState
			if not es.alive:
				to_release.append(id)
	for id: int in to_release:
		_release_entity(id)

	# Acquire / update nodes for live remotes
	for id: Variant in remotes:
		var es: EntityState = remotes[id] as EntityState
		if not es.alive:
			continue
		var node: MeshInstance3D = _acquire_entity(int(id), es.team)
		_pose_entity(node, es)


func _acquire_entity(id: int, team: int) -> MeshInstance3D:
	if _active.has(id):
		return _active[id] as MeshInstance3D
	# Reuse from free list or create new
	var node: MeshInstance3D
	if not _free_list.is_empty():
		node = _free_list.pop_back() as MeshInstance3D
	else:
		node = _make_entity_mesh()
		add_child(node)
	node.visible = true
	# Apply team tint
	var mat := StandardMaterial3D.new()
	mat.albedo_color = TEAM_COLOR[team] if team < TEAM_COLOR.size() else NEUTRAL_COLOR
	node.material_override = mat
	_active[id] = node
	return node


func _release_entity(id: int) -> void:
	if not _active.has(id):
		return
	var node: MeshInstance3D = _active[id] as MeshInstance3D
	node.visible = false
	_active.erase(id)
	_free_list.append(node)


func _pose_entity(node: MeshInstance3D, es: EntityState) -> void:
	var pose: Dictionary = StancePose.of(es.stance, es.lean, es.is_downed, es.climbing)
	var height: float = pose["height"] as float
	var y_offset: float = pose["y_offset"] as float
	var tilt: float = pose["tilt"] as float

	# Position: entity pos + lift by y_offset so the base stays on floor
	node.position = Vector3(es.pos.x, es.pos.y + y_offset, es.pos.z)

	# Orientation: yaw around Y, then lean tilt around Z (local forward = -Z)
	var rot := Basis.from_euler(Vector3(0.0, es.yaw, tilt))
	node.transform.basis = rot

	# Scale capsule height dynamically (CapsuleMesh height is along Y)
	# We set scale.y to reflect the stance height relative to the default height.
	# Default mesh height is 1.0; scale to match sim body_height.
	node.scale = Vector3(1.0, height, 1.0)


# =============================================================================
#  Camera helper
# =============================================================================

func _apply_camera(predictor: Prediction, fov: float) -> void:
	if _camera == null:
		return
	var pawn: Pawn = predictor.predicted
	var eye: Vector3 = pawn.eye_position()
	_camera.position = eye
	# yaw around Y, then pitch around X (camera local)
	_camera.transform.basis = Basis.from_euler(Vector3(pawn.pitch, pawn.yaw, 0.0))
	_camera.fov = fov


# =============================================================================
#  Mesh / material factories (swap here in P2 without touching netcode)
# =============================================================================

func _make_entity_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.3
	mesh.height = 1.0    # default; scaled per-frame in _pose_entity()
	mi.mesh = mesh
	return mi


func _make_cylinder_marker(radius: float, height: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	mi.material_override = mat
	return mi


func _make_box_mesh(size: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	return mi

class_name WorldRenderer
extends Node3D
## Presentation-only renderer. Reads MapDef + WorldView + Prediction each frame and draws
## placeholder primitives. Contains NO gameplay or authority logic (AGENTS.md §7, ADR-0005).
## P2 can swap meshes by changing _make_entity_mesh() / _make_ground_mesh() etc. without
## touching netcode or calling code.

# -- team colours (placeholder tint) ------------------------------------------
const TEAM_COLOR := [Color(0.2, 0.5, 1.0), Color(1.0, 0.3, 0.2)]  # [team0=blue, team1=red]
const NEUTRAL_COLOR := Color(0.6, 0.6, 0.6)

# -- structure type colours (placeholder tint, index == PieceCatalog type int) --
const STRUCTURE_TYPE_COLORS := [
	Color(0.70, 0.55, 0.35),   # type 0: wood   — warm tan
	Color(0.55, 0.55, 0.60),   # type 1: metal  — cool grey
	Color(0.65, 0.60, 0.55),   # type 2: concrete — warm grey
]
const STRUCTURE_DEFAULT_COLOR := Color(0.60, 0.58, 0.56)

# -- structure feedback timing ------------------------------------------------
const STRUCT_SPAWN_DUR := 0.18     # seconds for build pop scale-up
const STRUCT_DESTROY_DUR := 0.14   # seconds for destroy pop scale-down before release

# -- viewmodel placeholder dimensions -----------------------------------------
const VM_SIZE := Vector3(0.08, 0.08, 0.35)
const VM_OFFSET := Vector3(0.15, -0.12, -0.40)   # right / down / forward in camera space

# -- tracer (shot feedback) ---------------------------------------------------
const TRACER_POOL := 16
const TRACER_LEN := 80.0          # metres the beam extends along the aim
const TRACER_TTL := 0.06          # seconds the beam is visible (brief flash)
const TRACER_COLOR := Color(1.0, 0.85, 0.35)

# -- pool state ---------------------------------------------------------------
var _camera: Camera3D = null
var _tracers: Array = []          # [{node: MeshInstance3D, mat: StandardMaterial3D, die: float}]
var _tracer_idx: int = 0

# active entity nodes: id(int) -> MeshInstance3D
var _active: Dictionary = {}
# free list for recycled entity MeshInstance3D nodes
var _free_list: Array = []

# active structure nodes: id(int) -> MeshInstance3D
var _struct_active: Dictionary = {}
# free list for recycled structure MeshInstance3D nodes
var _struct_free_list: Array = []
# active vehicle nodes: vid(int) -> MeshInstance3D (placeholder boxes; VehicleState has no team)
var _vehicle_active: Dictionary = {}
var _vehicle_free_list: Array = []
const VEHICLE_COLOR := Color(0.30, 0.34, 0.22)   # olive — neutral placeholder, no team field on wire
# structures pending a destroy pop: id(int) -> {node:MeshInstance3D, die:float, tween:Tween}
var _struct_dying: Dictionary = {}

# viewmodel box (optional placeholder)
var _viewmodel: MeshInstance3D = null


# =============================================================================
#  Public interface
# =============================================================================

## Build static world geometry once. Call before any update().
func setup(map: MapDef, camera: Camera3D) -> void:
	_camera = camera
	# Interpret settings.fov as HORIZONTAL fov (BattleBit-style). Godot defaults to KEEP_HEIGHT
	# (vertical), which turns fov=90 into ~121° horizontal on 16:9 — the "fisheye" warp at edges.
	_camera.keep_aspect = Camera3D.KEEP_WIDTH

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

	# Capture point markers — ground cylinder + a tall beacon so the point is a visible
	# landmark from across the map (flat terrain is otherwise impossible to navigate).
	for pt: Dictionary in map.points:
		var pt_pos: Vector3 = pt["pos"] as Vector3
		var pt_radius: float = pt["radius"] as float
		var marker := _make_cylinder_marker(pt_radius * 0.5, 0.4, NEUTRAL_COLOR)
		marker.position = Vector3(pt_pos.x, 0.2, pt_pos.z)
		add_child(marker)
		var beacon := _make_box_mesh(Vector3(1.2, 30.0, 1.2), Color(0.95, 0.85, 0.25))
		beacon.position = Vector3(pt_pos.x, 15.0, pt_pos.z)
		add_child(beacon)

	# Base markers — team-coloured larger cylinders
	for b: Dictionary in map.bases:
		var b_team: int = b["team"] as int
		var b_pos: Vector3 = b["pos"] as Vector3
		var b_radius: float = b["radius"] as float
		var col: Color = TEAM_COLOR[b_team] if b_team < TEAM_COLOR.size() else NEUTRAL_COLOR
		var base_marker := _make_cylinder_marker(b_radius * 0.4, 0.8, col)
		base_marker.position = Vector3(b_pos.x, 0.4, b_pos.z)
		add_child(base_marker)
		# Tall team-coloured beacon at each base — a navigation landmark.
		var base_beacon := _make_box_mesh(Vector3(2.0, 40.0, 2.0), col)
		base_beacon.position = Vector3(b_pos.x, 20.0, b_pos.z)
		add_child(base_beacon)

	# Tracer pool — thin emissive beams along the aim, hidden until fired.
	for _i in TRACER_POOL:
		var tn := MeshInstance3D.new()
		var tmesh := BoxMesh.new()
		tmesh.size = Vector3(0.06, 0.06, TRACER_LEN)
		tn.mesh = tmesh
		var tmat := StandardMaterial3D.new()
		tmat.albedo_color = TRACER_COLOR
		tmat.emission_enabled = true
		tmat.emission = TRACER_COLOR
		tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		tmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		tn.material_override = tmat
		tn.visible = false
		tn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(tn)
		_tracers.append({"node": tn, "mat": tmat, "die": 0.0})

	# Viewmodel placeholder (parented to camera so it moves with it)
	_viewmodel = _make_box_mesh(VM_SIZE, Color(0.5, 0.5, 0.5))
	_viewmodel.position = VM_OFFSET
	# NOTE: we parent it to camera later in _apply_camera() to keep transforms clean.
	# For now it is not added; client_main can add it after setup() if desired.
	# Kept as an optional hook — Task 25 can wire it.


## Per-frame update. Safe to call with null world_view or predictor (early-returns).
func update(world_view: WorldView, predictor: Prediction, now: float, fov: float,
		look_yaw: float = 0.0, look_pitch: float = 0.0, eye: Vector3 = Vector3.INF) -> void:
	if world_view == null or predictor == null:
		return

	# 1. Entity pool update
	var remotes: Dictionary = world_view.remotes_at(now)
	_sync_entity_pool(remotes)

	# 2. Structure pool update
	_sync_structure_pool(world_view.structures(), now)

	# 2b. Vehicle pool update (placeholder boxes so vehicles are visible + interactable)
	_sync_vehicle_pool(world_view.vehicles())

	# 3. Camera from prediction (position) + client look (rotation)
	_apply_camera(predictor, fov, look_yaw, look_pitch, eye)

	# 4. Age out shot tracers
	_age_tracers(now)


## Spawn a brief tracer beam along the camera's aim. Called when the weapon predictor reports a
## shot fired. Drawn along the real camera forward (-Z), so it goes exactly where the crosshair
## points regardless of the sim's yaw convention.
func fire_tracer(now: float) -> void:
	if _camera == null or _tracers.is_empty():
		return
	var cb := _camera.global_transform
	var fwd := (-cb.basis.z).normalized()
	# Muzzle: from the eye, nudged right/down/forward so the beam doesn't emit from screen centre.
	var origin := cb.origin + cb.basis.x * 0.18 - cb.basis.y * 0.12 + fwd * 0.5
	var up := Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var t: Dictionary = _tracers[_tracer_idx]
	_tracer_idx = (_tracer_idx + 1) % _tracers.size()
	var node: MeshInstance3D = t["node"]
	node.global_transform = Transform3D(Basis.looking_at(fwd, up), origin + fwd * (TRACER_LEN * 0.5))
	(t["mat"] as StandardMaterial3D).albedo_color = TRACER_COLOR
	node.visible = true
	t["die"] = now + TRACER_TTL


func _age_tracers(now: float) -> void:
	for t: Dictionary in _tracers:
		var node: MeshInstance3D = t["node"]
		if not node.visible:
			continue
		var remaining: float = float(t["die"]) - now
		if remaining <= 0.0:
			node.visible = false
		else:
			var c := TRACER_COLOR
			c.a = clampf(remaining / TRACER_TTL, 0.0, 1.0)
			(t["mat"] as StandardMaterial3D).albedo_color = c


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
#  Structure pool helpers
# =============================================================================

func _sync_structure_pool(structs: Dictionary, now: float) -> void:
	# Tick dying pops — release when their tween has finished (tracked by die time)
	var to_finish: Array = []
	for id: int in _struct_dying:
		var entry: Dictionary = _struct_dying[id]
		if now >= float(entry["die"]):
			to_finish.append(id)
	for id: int in to_finish:
		var entry: Dictionary = _struct_dying[id]
		var node: MeshInstance3D = entry["node"] as MeshInstance3D
		_struct_dying.erase(id)
		_struct_release_node(node)

	# Release nodes for ids that have been removed from the store
	var to_release: Array = []
	for id: int in _struct_active:
		if not structs.has(id):
			to_release.append(id)
	for id: int in to_release:
		_start_destroy_pop(id, now)

	# Acquire / update nodes for all known structures
	for id_v: Variant in structs:
		var id: int = int(id_v)
		var rec: Dictionary = structs[id_v]
		var is_new := not _struct_active.has(id)
		var node: MeshInstance3D = _acquire_structure(id, rec)
		_pose_structure(node, rec)
		if is_new:
			_start_build_pop(node)


func _acquire_structure(id: int, rec: Dictionary) -> MeshInstance3D:
	if _struct_active.has(id):
		return _struct_active[id] as MeshInstance3D
	# Reuse from free list or create new
	var node: MeshInstance3D
	if not _struct_free_list.is_empty():
		node = _struct_free_list.pop_back() as MeshInstance3D
	else:
		node = _make_structure_mesh()
		add_child(node)
	node.visible = true
	# Apply type tint
	var type_idx: int = int(rec.get("type", 0))
	var col: Color = STRUCTURE_TYPE_COLORS[type_idx] \
		if type_idx < STRUCTURE_TYPE_COLORS.size() else STRUCTURE_DEFAULT_COLOR
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	node.material_override = mat
	_struct_active[id] = node
	return node


func _start_destroy_pop(id: int, now: float) -> void:
	# If already in dying list (e.g. double remove), skip
	if _struct_dying.has(id):
		return
	var node: MeshInstance3D = _struct_active[id] as MeshInstance3D
	_struct_active.erase(id)
	# Scale-down tween as destroy feedback
	var tw: Tween = create_tween()
	tw.tween_property(node, "scale", Vector3.ZERO, STRUCT_DESTROY_DUR)
	_struct_dying[id] = {"node": node, "die": now + STRUCT_DESTROY_DUR, "tween": tw}


func _struct_release_node(node: MeshInstance3D) -> void:
	node.visible = false
	node.scale = Vector3.ONE   # reset scale for reuse
	_struct_free_list.append(node)


func _start_build_pop(node: MeshInstance3D) -> void:
	# Scale-up from near-zero as spawn feedback; reuses create_tween() (Godot 4 Node method)
	node.scale = Vector3(0.05, 0.05, 0.05)
	var tw: Tween = create_tween()
	tw.tween_property(node, "scale", Vector3.ONE, STRUCT_SPAWN_DUR) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _pose_structure(node: MeshInstance3D, rec: Dictionary) -> void:
	# Cell centre: cell_min + half a cell on each axis (matches BuildGrid.world_of / cell_min).
	# BuildGrid.CELL_SIZE = 2.0 m; pieces sit with their base at cell.y * CELL_SIZE.
	var cell: Vector3i = rec["cell"] as Vector3i
	var half := BuildGrid.CELL_SIZE * 0.5
	var base := Vector3(float(cell.x) * BuildGrid.CELL_SIZE,
						float(cell.y) * BuildGrid.CELL_SIZE,
						float(cell.z) * BuildGrid.CELL_SIZE)
	node.position = base + Vector3(half, half, half)
	# Yaw is a step index (0..YAW_STEPS-1); convert to radians and orient around Y.
	var yaw_rad := BuildGrid.yaw_radians(int(rec.get("yaw", 0)))
	node.transform.basis = Basis.from_euler(Vector3(0.0, yaw_rad, 0.0))
	# Health feedback: darken material by bucket (3=pristine..0=heavy).
	# Recompute from the canonical type colour each frame so the tint stays consistent.
	var type_idx: int = int(rec.get("type", 0))
	var base_col: Color = STRUCTURE_TYPE_COLORS[type_idx] \
		if type_idx < STRUCTURE_TYPE_COLORS.size() else STRUCTURE_DEFAULT_COLOR
	if rec.has("bucket"):
		var bucket: int = int(rec["bucket"])   # 0..3; 3=pristine
		var brightness: float = 0.35 + 0.65 * (float(bucket) / 3.0)
		base_col = base_col * brightness   # scale RGB, preserve reference alpha
	var mat := node.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = base_col


# =============================================================================
#  Camera helper
# =============================================================================

func _apply_camera(predictor: Prediction, fov: float, look_yaw: float, look_pitch: float,
		eye: Vector3 = Vector3.INF) -> void:
	if _camera == null:
		return
	var pawn: Pawn = predictor.predicted
	# Interpolated eye between physics ticks (render-rate smoothness); fall back to the raw
	# predicted eye if no interpolated value was supplied.
	_camera.position = eye if eye.is_finite() else pawn.eye_position()
	# Rotation uses the client-authoritative LOOK (input) yaw/pitch, not the server-reconciled
	# pawn yaw. That lets the wire carry a flipped aim yaw (yaw+PI, to match Combat._forward to
	# where the camera points) without the reconciled value rotating the view 180°.
	_camera.transform.basis = Basis.from_euler(Vector3(look_pitch, look_yaw, 0.0))
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
	# Placeholder gun barrel so a pawn's facing / aim direction is readable (capsules are round).
	# The entity node's local +Z is its forward (Combat._forward via es.yaw), so a box sticking out
	# +Z points where the pawn is aiming. Child of the capsule -> inherits the yaw rotation.
	var gun := MeshInstance3D.new()
	var gmesh := BoxMesh.new()
	gmesh.size = Vector3(0.08, 0.08, 0.6)
	gun.mesh = gmesh
	gun.position = Vector3(0.22, 0.1, 0.45)   # held on the right, chest height, barrel forward
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.08, 0.08, 0.08)
	gun.material_override = gmat
	gun.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_child(gun)
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


func _make_structure_mesh() -> MeshInstance3D:
	# Placeholder: a BoxMesh sized to one full build cell (2 m cube).
	# Half-height pieces share the same node; _pose_structure scales Y to 0.5 for halves is
	# handled via the mesh size only — keeping scale=1 so build-pop tweens work cleanly.
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(BuildGrid.CELL_SIZE * 0.92,   # slight gap so adjacent pieces are distinct
						BuildGrid.CELL_SIZE * 0.92,
						BuildGrid.CELL_SIZE * 0.92)
	mi.mesh = mesh
	# material_override assigned at acquire time (type tint); roughness set here as default.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = STRUCTURE_DEFAULT_COLOR
	mat.roughness = 0.85
	mi.material_override = mat
	return mi


# =============================================================================
#  Vehicle pool (placeholder boxes — no team field on the wire, so neutral tint)
# =============================================================================
func _sync_vehicle_pool(vehicles: Dictionary) -> void:
	# Release nodes whose vid is gone from the view.
	var to_release: Array = []
	for vid: int in _vehicle_active:
		if not vehicles.has(vid):
			to_release.append(vid)
	for vid: int in to_release:
		var node: MeshInstance3D = _vehicle_active[vid] as MeshInstance3D
		_vehicle_active.erase(vid)
		node.visible = false
		_vehicle_free_list.append(node)
	# Acquire / pose nodes for all visible vehicles.
	for vid_v: Variant in vehicles:
		var vid: int = int(vid_v)
		var vs: VehicleState = vehicles[vid_v]
		if vs == null:
			continue
		var node: MeshInstance3D = _acquire_vehicle(vid)
		# Box is ~1.6 m tall; lift by half so it rests on the ground at vs.pos.
		node.position = vs.pos + Vector3(0.0, 0.8, 0.0)
		node.transform.basis = Basis.from_euler(Vector3(0.0, vs.heading, 0.0))


func _acquire_vehicle(vid: int) -> MeshInstance3D:
	if _vehicle_active.has(vid):
		return _vehicle_active[vid] as MeshInstance3D
	var node: MeshInstance3D
	if not _vehicle_free_list.is_empty():
		node = _vehicle_free_list.pop_back() as MeshInstance3D
	else:
		node = _make_vehicle_mesh()
		add_child(node)
	node.visible = true
	_vehicle_active[vid] = node
	return node


func _make_vehicle_mesh() -> MeshInstance3D:
	# Placeholder transport: a box roughly 2.4 W x 1.6 H x 5.0 L (forward = +Z, matches heading yaw).
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.4, 1.6, 5.0)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = VEHICLE_COLOR
	mat.roughness = 0.8
	mi.material_override = mat
	return mi

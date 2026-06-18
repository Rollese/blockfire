class_name WorldRenderer
extends Node3D
## Presentation-only renderer. Reads MapDef + WorldView + Prediction each frame and draws the
## procedural low-poly art kit (client/art/*_kit.gd). Contains NO gameplay or authority logic
## (AGENTS.md §7, ADR-0005). Meshes come from the kits; swap kit internals without touching this.

# -- team colours (markers/beacons; kits own their own tints) ------------------
const TEAM_COLOR := [Color(0.2, 0.5, 1.0), Color(1.0, 0.3, 0.2)]  # [team0=blue, team1=red]
const NEUTRAL_COLOR := Color(0.6, 0.6, 0.6)

# -- structure type -> PieceCatalog id (array order == wire `type` int; see pieces/*.json) -----
# fortifications.json order: 0 = sandbag, 1 = wall. Unknown/extra types fall back to "wall"
# (StructureKit also falls back to "wall" for any id it doesn't know).
const STRUCT_TYPE_ID := ["sandbag", "wall"]

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

# -- muzzle flash pool (MuzzleFlashKit; mirrors the tracer pool) ---------------
const FLASH_POOL := 16
var _flashes: Array = []          # [{node: MeshInstance3D, mat: StandardMaterial3D, die: float}]
var _flash_idx: int = 0

# active entity nodes: id(int) -> Node3D (CharacterKit soldier)
var _active: Dictionary = {}
# free list for recycled entity Node3D roots (all soldiers are identical — no per-team re-tint)
var _free_list: Array = []
# Character render mode: false = procedural CharacterKit (default), true = imported GLB model.
var use_models: bool = false
# Per-id last position + AnimationPlayer, for the per-frame speed estimate that selects the clip.
var _last_pos: Dictionary = {}        # id(int) -> Vector3
var _entity_ap: Dictionary = {}       # id(int) -> AnimationPlayer (only when use_models)

# active structure nodes: id(int) -> Node3D (StructureKit piece)
var _struct_active: Dictionary = {}
# id(int) -> "type:bucket" key; a change means rebuild (kit geometry/tint is baked at build)
var _struct_key_of: Dictionary = {}
# friend markers: id(int) -> MeshInstance3D (blue triangle above teammates; BattleBit-style)
var _friend_markers: Dictionary = {}
var _marker_free_list: Array = []
const FRIEND_MARKER_Y := 2.35    # world height above the pawn's feet (fixed; ignores stance squash)
const PRONE_LIFT := 0.3          # small lift so a flat-lying prone/downed body rests on the ground
# active vehicle nodes: vid(int) -> Node3D (VehicleKit transport; VehicleState carries no team)
var _vehicle_active: Dictionary = {}
var _vehicle_free_list: Array = []
const VEHICLE_SMOOTH_RATE := 16.0                # higher = snappier; ~1/e catch-up in ~60 ms
# structures pending a destroy pop: id(int) -> {node:Node3D, die:float, tween:Tween}
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

	# Muzzle flash pool — brief emissive plates at the muzzle, hidden until a shot is fired.
	for _i in FLASH_POOL:
		var fn := MuzzleFlashKit.build()
		fn.visible = false
		add_child(fn)
		_flashes.append({"node": fn, "mat": fn.material_override, "die": 0.0})

	# Viewmodel placeholder (parented to camera so it moves with it)
	_viewmodel = _make_box_mesh(VM_SIZE, Color(0.5, 0.5, 0.5))
	_viewmodel.position = VM_OFFSET
	# NOTE: we parent it to camera later in _apply_camera() to keep transforms clean.
	# For now it is not added; client_main can add it after setup() if desired.
	# Kept as an optional hook — Task 25 can wire it.


## Per-frame update. Safe to call with null world_view or predictor (early-returns).
func update(world_view: WorldView, predictor: Prediction, now: float, fov: float,
		look_yaw: float = 0.0, look_pitch: float = 0.0, eye: Vector3 = Vector3.INF,
		render_delta: float = 0.0) -> void:
	if world_view == null or predictor == null:
		return

	# 1. Entity pool update. Friend/foe is shown by a marker above friendlies (BattleBit-style),
	# not by body colour — so we need the local player's team. self_state() is the local pawn's
	# authoritative EntityState (null while dead/pre-spawn -> no friend markers that frame).
	var remotes: Dictionary = world_view.remotes_at(now)
	var self_es: EntityState = world_view.self_state()
	var local_team: int = self_es.team if self_es != null else -1
	_sync_entity_pool(remotes, local_team, render_delta)

	# 2. Structure pool update
	_sync_structure_pool(world_view.structures(), now)

	# 2b. Vehicle pool update (placeholder boxes so vehicles are visible + interactable).
	# Uses the real render-frame delta (not `now`, which only advances at the 30 Hz sim rate)
	# so smoothing runs per render frame.
	_sync_vehicle_pool(world_view.vehicles(), render_delta)

	# 3. Camera from prediction (position) + client look (rotation)
	_apply_camera(predictor, fov, look_yaw, look_pitch, eye)

	# 4. Age out shot tracers
	_age_tracers(now)
	_age_flashes(now)


## Spawn a brief tracer beam along the camera's aim. Called when the weapon predictor reports a
## shot fired. Drawn along the real camera forward (-Z), so it goes exactly where the crosshair
## points regardless of the sim's yaw convention.
func fire_tracer(now: float) -> void:
	if _camera == null:
		return
	var cb := _camera.global_transform
	var fwd := (-cb.basis.z).normalized()
	# Muzzle: from the eye, nudged right/down/forward so the beam doesn't emit from screen centre.
	var origin := cb.origin + cb.basis.x * 0.18 - cb.basis.y * 0.12 + fwd * 0.5
	_spawn_tracer(origin, fwd, now)


## Cosmetic tracer for a REMOTE pawn's shot (from a server SHOT_FX): a beam from the shooter's
## muzzle along their aim, so other players' fire is readable instead of looking like statues.
func tracer_from(origin: Vector3, dir: Vector3, now: float) -> void:
	if dir.length() < 0.001:
		return
	_spawn_tracer(origin, dir.normalized(), now)


func _spawn_tracer(origin: Vector3, fwd: Vector3, now: float) -> void:
	if _tracers.is_empty():
		return
	var up := Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var t: Dictionary = _tracers[_tracer_idx]
	_tracer_idx = (_tracer_idx + 1) % _tracers.size()
	var node: MeshInstance3D = t["node"]
	node.global_transform = Transform3D(Basis.looking_at(fwd, up), origin + fwd * (TRACER_LEN * 0.5))
	(t["mat"] as StandardMaterial3D).albedo_color = TRACER_COLOR
	node.visible = true
	t["die"] = now + TRACER_TTL
	_spawn_flash(origin, fwd, now)


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


func _spawn_flash(origin: Vector3, fwd: Vector3, now: float) -> void:
	if _flashes.is_empty():
		return
	var up := Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var f: Dictionary = _flashes[_flash_idx]
	_flash_idx = (_flash_idx + 1) % _flashes.size()
	var node: MeshInstance3D = f["node"]
	node.global_transform = Transform3D(Basis.looking_at(fwd, up), origin)
	var c := MuzzleFlashKit.COLOR
	c.a = 1.0
	(f["mat"] as StandardMaterial3D).albedo_color = c
	node.visible = true
	f["die"] = now + MuzzleFlashKit.TTL


func _age_flashes(now: float) -> void:
	for f: Dictionary in _flashes:
		var node: MeshInstance3D = f["node"]
		if not node.visible:
			continue
		var remaining: float = float(f["die"]) - now
		if remaining <= 0.0:
			node.visible = false
		else:
			var c := MuzzleFlashKit.COLOR
			c.a = MuzzleFlashKit.alpha_for(remaining, MuzzleFlashKit.TTL)
			(f["mat"] as StandardMaterial3D).albedo_color = c


# =============================================================================
#  Entity pool helpers (CharacterKit soldiers)
# =============================================================================

func _sync_entity_pool(remotes: Dictionary, local_team: int, render_delta: float) -> void:
	# Release nodes for ids that are gone or dead (and their friend markers)
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
		_release_marker(id)

	# Acquire / update nodes for live remotes; mark friendlies (same team as the local player).
	for id: Variant in remotes:
		var es: EntityState = remotes[id] as EntityState
		if not es.alive:
			continue
		var node: Node3D = _acquire_entity(int(id))
		_pose_entity(int(id), node, es, render_delta)
		if local_team >= 0 and es.team == local_team:
			var marker: MeshInstance3D = _acquire_marker(int(id))
			marker.position = Vector3(es.pos.x, es.pos.y + FRIEND_MARKER_Y, es.pos.z)
		else:
			_release_marker(int(id))


func _acquire_entity(id: int) -> Node3D:
	if _active.has(id):
		return _active[id] as Node3D
	# Reuse from free list or create new. Soldiers are not team-tinted (all identical), so a
	# recycled node needs no re-tint — friend/foe is the marker, handled separately.
	var node: Node3D
	if not _free_list.is_empty():
		node = _free_list.pop_back() as Node3D
	else:
		node = _make_entity_mesh()
		add_child(node)
	node.visible = true
	_active[id] = node
	# Always (re)bind the AnimationPlayer on acquire — a node recycled from the free list belongs to
	# this id now, so re-fetch rather than relying on release-time erase symmetry.
	if use_models:
		_entity_ap[id] = GlbCharacterKit.anim_player(node)
	return node


func _release_entity(id: int) -> void:
	if not _active.has(id):
		return
	var node: Node3D = _active[id] as Node3D
	node.visible = false
	_active.erase(id)
	_entity_ap.erase(id)
	_last_pos.erase(id)
	_free_list.append(node)


# -- friend markers (blue triangle above teammates) ---------------------------

func _acquire_marker(id: int) -> MeshInstance3D:
	if _friend_markers.has(id):
		return _friend_markers[id] as MeshInstance3D
	var node: MeshInstance3D
	if not _marker_free_list.is_empty():
		node = _marker_free_list.pop_back() as MeshInstance3D
	else:
		node = _make_friend_marker()
		add_child(node)
	node.visible = true
	_friend_markers[id] = node
	return node


func _release_marker(id: int) -> void:
	if not _friend_markers.has(id):
		return
	var node: MeshInstance3D = _friend_markers[id] as MeshInstance3D
	node.visible = false
	_friend_markers.erase(id)
	_marker_free_list.append(node)


func _make_friend_marker() -> MeshInstance3D:
	# Small downward-pointing cone = a triangle floating point-down above a teammate's head.
	# Unshaded + emissive so it reads clearly at any distance/lighting; never casts shadow.
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0          # apex
	mesh.bottom_radius = 0.16
	mesh.height = 0.26
	mi.mesh = mesh
	mi.rotation = Vector3(PI, 0.0, 0.0)   # flip apex to point down toward the head
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ArtPalette.FRIENDLY
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Always visible — even through walls/objects (BattleBit friendly markers). Ignore the depth
	# buffer and route through the transparent pass with max render priority so it draws on top of
	# all opaque geometry.
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.render_priority = 127
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _pose_entity(id: int, node: Node3D, es: EntityState, render_delta: float) -> void:
	if use_models:
		# Horizontal speed estimate from frame-to-frame position (velocity isn't replicated).
		var last: Vector3 = _last_pos.get(id, es.pos)
		var dt: float = maxf(render_delta, 0.001)   # 1 ms floor: avoid blowups from sub-ms deltas
		var flat := Vector3(es.pos.x - last.x, 0.0, es.pos.z - last.z)
		# Cap the estimate so a respawn/teleport jump can't read as a multi-frame sprint (one-frame
		# pop at worst, recovers next frame). 20 m/s is well above SPRINT_SPEED.
		var speed: float = minf(flat.length() / dt, 20.0)
		_last_pos[id] = es.pos
		var sel: Dictionary = CharacterAnim.clip_for(es.is_downed, speed, es.stance)
		CharacterDriver.drive(_entity_ap.get(id) as AnimationPlayer, sel["clip"], sel["loop"])
	var pose: Dictionary = StancePose.of(es.stance, es.lean, es.is_downed, es.climbing)
	var height: float = pose["height"] as float
	var tilt: float = pose["tilt"] as float

	if es.stance == Stance.PRONE or es.is_downed:
		# Lay the soldier flat along its facing direction (a vertical scale would crush the figure
		# into a blob). Prone = face-DOWN (crawling/firing); downed (DBNO) = face-UP, on the back, so
		# an incapacitated teammate reads differently from someone prone. Downed wins if both hold.
		var pitch: float = -PI * 0.5 if es.is_downed else PI * 0.5
		var b := Basis.IDENTITY
		b = b.rotated(Vector3.UP, es.yaw)
		b = b.rotated(b.x, pitch)   # +90 = head pitches forward/down (prone); -90 = onto the back (downed)
		node.transform.basis = b
		node.scale = Vector3.ONE
		node.position = Vector3(es.pos.x, es.pos.y + PRONE_LIFT, es.pos.z)
		return

	# Standing / crouch: upright, the kit's base sits at the pawn's feet (no capsule-centre lift).
	node.position = Vector3(es.pos.x, es.pos.y, es.pos.z)
	# Orientation: yaw around Y, then lean tilt around Z (local forward = +Z, gun mount at +Z).
	# Set basis BEFORE scale: assigning scale preserves rotation, but assigning basis resets scale.
	node.transform.basis = Basis.from_euler(Vector3(0.0, es.yaw, tilt))
	# Scale vertically to the stance body-height (crouch reads as a shorter, still-upright figure).
	node.scale = Vector3(1.0, height / CharacterKit.STAND_HEIGHT, 1.0)


# =============================================================================
#  Structure pool helpers (StructureKit pieces; rebuilt when piece/bucket changes)
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
		var node: Node3D = entry["node"] as Node3D
		_struct_dying.erase(id)
		node.queue_free()

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
		var was_present := _struct_active.has(id)
		var node: Node3D = _acquire_structure(id, rec)
		_pose_structure(node, rec)
		# Pop only on a genuinely new structure, not on a damage-driven rebuild (still present).
		if not was_present:
			_start_build_pop(node)


func _acquire_structure(id: int, rec: Dictionary) -> Node3D:
	var key := _struct_key(rec)
	if _struct_active.has(id):
		if String(_struct_key_of.get(id, "")) == key:
			return _struct_active[id] as Node3D
		# Piece type or damage bucket changed — the kit bakes geometry + tint at build time, so
		# rebuild rather than re-tint (a heavier bucket also adds a chip in silhouette).
		(_struct_active[id] as Node3D).queue_free()
		_struct_active.erase(id)
		_struct_key_of.erase(id)   # keep the two dicts moving together
	var node := _make_structure_node(rec)
	add_child(node)
	_struct_active[id] = node
	_struct_key_of[id] = key
	return node


func _struct_key(rec: Dictionary) -> String:
	return "%d:%d" % [int(rec.get("type", 0)), int(rec.get("bucket", 3))]


func _start_destroy_pop(id: int, now: float) -> void:
	# If already in dying list (e.g. double remove), skip
	if _struct_dying.has(id):
		return
	var node: Node3D = _struct_active[id] as Node3D
	_struct_active.erase(id)
	_struct_key_of.erase(id)
	# Scale-down tween as destroy feedback
	var tw: Tween = create_tween()
	tw.tween_property(node, "scale", Vector3.ZERO, STRUCT_DESTROY_DUR)
	_struct_dying[id] = {"node": node, "die": now + STRUCT_DESTROY_DUR, "tween": tw}


func _start_build_pop(node: Node3D) -> void:
	# Scale-up from near-zero as spawn feedback; reuses create_tween() (Godot 4 Node method)
	node.scale = Vector3(0.05, 0.05, 0.05)
	var tw: Tween = create_tween()
	tw.tween_property(node, "scale", Vector3.ONE, STRUCT_SPAWN_DUR) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _pose_structure(node: Node3D, rec: Dictionary) -> void:
	# Cell floor: the kit's base sits at y=0, so the piece rests on the cell floor (cell.y*CELL_SIZE)
	# and is centred horizontally in the cell. BuildGrid.CELL_SIZE = 2.0 m.
	var cell: Vector3i = rec["cell"] as Vector3i
	var half := BuildGrid.CELL_SIZE * 0.5
	node.position = Vector3(float(cell.x) * BuildGrid.CELL_SIZE + half,
							float(cell.y) * BuildGrid.CELL_SIZE,
							float(cell.z) * BuildGrid.CELL_SIZE + half)
	# Yaw is a step index (0..YAW_STEPS-1); convert to radians and orient around Y.
	var yaw_rad := BuildGrid.yaw_radians(int(rec.get("yaw", 0)))
	node.transform.basis = Basis.from_euler(Vector3(0.0, yaw_rad, 0.0))


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
#  Mesh / material factories (markers + kit roots)
# =============================================================================

func _make_entity_mesh() -> Node3D:
	# Soldiers share one uniform (no team tint); friend/foe is the marker above the head.
	var node: Node3D
	if use_models:
		node = GlbCharacterKit.build()
	else:
		node = CharacterKit.build()
	# Distance LOD: shed small parts with range, demote to a proxy box far away (Track A, spec §3).
	# Idempotent + done once at pool-build time, so no per-frame cost.
	Lod.apply_to_character(node)
	return node


func _make_structure_node(rec: Dictionary) -> Node3D:
	var type_idx: int = int(rec.get("type", 0))
	var piece_id: String = STRUCT_TYPE_ID[type_idx] if type_idx < STRUCT_TYPE_ID.size() else "wall"
	return StructureKit.build(piece_id, int(rec.get("bucket", 3)))


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


# =============================================================================
#  Vehicle pool (VehicleKit transport — no team field on the wire, so neutral tint)
# =============================================================================
func _sync_vehicle_pool(vehicles: Dictionary, render_delta: float) -> void:
	# Smoothing factor: vehicle states arrive only at the snapshot rate (~15 Hz), so posing the
	# box directly looks choppy. Exponential-smooth toward the latest snapshot each render frame
	# (framerate-independent via the real render delta). New vehicles snap into place; existing ease.
	var dt: float = clampf(render_delta, 0.0, 0.1)
	var k: float = 1.0 - exp(-dt * VEHICLE_SMOOTH_RATE)
	# Release nodes whose vid is gone from the view.
	var to_release: Array = []
	for vid: int in _vehicle_active:
		if not vehicles.has(vid):
			to_release.append(vid)
	for vid: int in to_release:
		var node: Node3D = _vehicle_active[vid] as Node3D
		_vehicle_active.erase(vid)
		node.visible = false
		_vehicle_free_list.append(node)
	# Acquire / pose nodes for all visible vehicles.
	for vid_v: Variant in vehicles:
		var vid: int = int(vid_v)
		var vs: VehicleState = vehicles[vid_v]
		if vs == null:
			continue
		var is_new := not _vehicle_active.has(vid)
		var node: Node3D = _acquire_vehicle(vid)
		# The kit's base (wheels) sits at y=0, so it rests on the ground directly at vs.pos.
		var target_pos: Vector3 = vs.pos
		if is_new or k <= 0.0:
			node.position = target_pos
			node.rotation = Vector3(0.0, vs.heading, 0.0)
		else:
			node.position = node.position.lerp(target_pos, k)
			node.rotation.y = lerp_angle(node.rotation.y, vs.heading, k)


func _acquire_vehicle(vid: int) -> Node3D:
	if _vehicle_active.has(vid):
		return _vehicle_active[vid] as Node3D
	var node: Node3D
	if not _vehicle_free_list.is_empty():
		node = _vehicle_free_list.pop_back() as Node3D
	else:
		node = _make_vehicle_mesh()
		add_child(node)
	node.visible = true
	_vehicle_active[vid] = node
	return node


func _make_vehicle_mesh() -> Node3D:
	# Neutral transport — VehicleState carries no team field on the wire, so build with the
	# neutral tint (team -1 -> ArtPalette neutral). Forward = +Z, matches heading yaw.
	return VehicleKit.build("transport", -1)

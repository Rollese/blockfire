class_name WorldRenderer
extends Node3D
## Presentation-only renderer. Reads MapDef + WorldView + Prediction each frame and draws the
## procedural low-poly art kit (client/art/*_kit.gd). Contains NO gameplay or authority logic
## (AGENTS.md §7, ADR-0005). Meshes come from the kits; swap kit internals without touching this.

# -- team colours (markers/beacons; kits own their own tints) ------------------
const TEAM_COLOR := [Color(0.2, 0.5, 1.0), Color(1.0, 0.3, 0.2)]  # [team0=blue, team1=red]
const NEUTRAL_COLOR := Color(0.6, 0.6, 0.6)

# -- structure type -> PieceCatalog id (array order == wire `type` int; see pieces/pieces.json) -----
# pieces.json order: 0 = sandbag, 1 = wall, 2+ = building pieces. Unknown/extra types fall back to "wall"
# (StructureKit also falls back to "wall" for any id it doesn't know).
const STRUCT_TYPE_ID := ["sandbag", "wall", "bwall", "bwall_window", "bwall_door", "bfloor", "bstair", "bcolumn", "brailing", "prop_crate", "bwall_half", "bwall_brick", "bwall_metal", "bwall_wood", "bwall_garage", "bwall_glass", "prop_table", "prop_chair", "prop_shelf", "prop_locker", "prop_barrel", "bwall_corner"]

# -- structure type -> chunk-grid (mirror of pieces/pieces.json `chunk_grid`) ----------
# Needed to turn a piece's live chunk alive-mask into a damage tier. Keep aligned with STRUCT_TYPE_ID
# order; unknown types fall back to the 8x8 fortification grid.
const STRUCT_TYPE_GRID := [8, 8, 8, 8, 8, 8, 8, 8, 4, 1, 8, 8, 8, 8, 8, 8, 1, 1, 1, 1, 1, 8]

# -- structure feedback timing ------------------------------------------------
const STRUCT_LIFT := 0.06          # m: lift buildings onto a thin foundation (no grass z-fight)
const STRUCT_SPAWN_DUR := 0.18     # seconds for build pop scale-up
const STRUCT_DESTROY_DUR := 0.14   # seconds for destroy pop scale-down before release

# -- viewmodel placeholder dimensions -----------------------------------------
const VM_OFFSET := Vector3(0.15, -0.12, -0.28)   # right / down / forward in camera space (pulled back from -0.40 — was too far forward)
const VM_YAW := PI   # GlbWeaponKit aims the barrel +Z; camera-forward is -Z, so flip 180° to aim with the view

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

# RPG rocket cosmetics — a launched rocket (local shooter feedback + replicated ROCKET_FX) flies the
# shared Grenade ballistic arc so it tracks where the server's real rocket goes, trailing smoke and
# popping a puff on impact. Presentation-only; the server owns the actual blast.
const ROCKET_SPEED := 150.0       # MUST match data/gadgets.json rpg rocket_speed
const ROCKET_LIFETIME := 5.0      # s safety cap before a cosmetic rocket self-despawns
const ROCKET_TRAIL_DT := 0.03     # s between trail puffs
var _rockets: Array = []          # [{node: Node3D, vel: Vector3, die: float, next_puff: float}]
var _puffs: Array = []            # [{node, mat, die, ttl}] — smoke trail + impact puffs
var _blasts: Array = []           # [{node, mat, born, die, ttl, s0, s1, color}] — explosion fireball cores
var _debris: Array = []           # [{node, vel, die}] — explosion debris chunks
var boom_demo := false            # --boom-test: pump frag explosions in front of the camera (QA)
var _boom_next := 0.0
var _boom_i := 0
# corpse-on-death: a body left where a pawn died (alive->false in view), lingering then despawning.
const CORPSE_TTL := 14.0          # seconds a corpse lingers before despawn
const CORPSE_FADE := 1.0          # seconds of sink-into-ground at the end of life
const CORPSE_MAX := 40            # cap; oldest is removed when exceeded (bounds cost at fleet density)
var _corpses: Array = []          # [{node: Node3D, die: float, y0: float}]
var corpse_demo := false          # --corpse-test: lay a few corpses in front of the camera (QA)
var _corpse_demo_done := false

# active entity nodes: id(int) -> Node3D (CharacterKit soldier)
var _active: Dictionary = {}
# free list for recycled entity Node3D roots (all soldiers are identical — no per-team re-tint)
var _free_list: Array = []
# Character render mode: false = procedural CharacterKit (default), true = imported GLB model.
var use_models: bool = false
# Per-id last position + AnimationPlayer, for the per-frame speed estimate that selects the clip.
var _last_pos: Dictionary = {}        # id(int) -> Vector3
var _last_speed: Dictionary = {}      # id(int) -> float (held between sim ticks; see _pose_entity)
var _armor_tier: Dictionary = {}      # id(int) -> last-applied armor tier (re-tint only on change)
var armor_demo := false               # --armor-demo: pin LIGHT/MEDIUM/HEAVY dummies in front of camera
var _armor_demo_done := false
var _entity_ap: Dictionary = {}       # id(int) -> AnimationPlayer (only when use_models)

# active structure nodes: id(int) -> Node3D (StructureKit piece)
var _struct_active: Dictionary = {}
# id(int) -> "type:bucket" key; a change means rebuild (kit geometry/tint is baked at build)
var _struct_key_of: Dictionary = {}
# last WorldView.structs_version() we synced; the per-frame pool walk is skipped while unchanged
# (structures are static, so re-acquiring/re-posing ~thousands of pieces every frame was the
# dominant client cost on dense maps — 35 ms/frame on conquest_town's 77 buildings).
var _struct_synced_ver: int = -1
# set by _acquire_structure when it (re)builds a node, so we only re-pose changed pieces
var _struct_rebuilt: bool = false
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
# M11: building_id(int) -> last-posed piece position; rubble spawns here on COLLAPSE.
var _building_centroid: Dictionary = {}

# viewmodel box (optional placeholder)
var _viewmodel: Node3D = null
var _viewmodel_weapon: int = -1   # currently-built viewmodel weapon id; rebuild on change
# first-person viewmodel animation (M7): swing (melee) + swap (weapon change), procedural offsets.
var _vm_anim_kind: int = -1       # -1 = none; else ViewmodelAnim.SWING/SWAP
var _vm_anim_start: float = 0.0
var _vm_anim_dur: float = 0.0
var _now: float = 0.0             # cached update() time, so set_viewmodel_weapon can start an anim
var vm_swing_test := false        # --swing-test: hold the viewmodel mid-swing for a QA screenshot
var vm_recoil_test := false       # --recoil-test: hold the viewmodel mid-recoil-kick for a QA screenshot


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
	# Procedural two-tone green so the open terrain reads as ground with low-frequency patches,
	# not one flat infinite plane. Noise is generated in-engine (no asset file); roads/buildings
	# sit on top so only the open areas show it. Kept subtle — depth cue, not a loud pattern.
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(1, 1, 1)
	gmat.roughness = 1.0
	var gnoise := FastNoiseLite.new()
	gnoise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	gnoise.frequency = 0.025
	var gtex := NoiseTexture2D.new()
	gtex.width = 256
	gtex.height = 256
	gtex.seamless = true
	gtex.noise = gnoise
	var gramp := Gradient.new()
	gramp.set_color(0, Color(0.20, 0.29, 0.16))   # darker patch
	gramp.set_color(1, Color(0.29, 0.39, 0.22))   # lighter patch
	gtex.color_ramp = gramp
	gmat.albedo_texture = gtex
	var gtile := side / 70.0   # ~70 m per texture repeat — organic, not obviously tiled
	gmat.uv1_scale = Vector3(gtile, gtile, 1.0)
	ground.material_override = gmat
	add_child(ground)

	# Roads — flat dark-grey asphalt strips laid just above the ground (cosmetic, no collision).
	# A faint yellow centre-line is drawn down the long axis so the road network reads as a network.
	for rd: Dictionary in map.roads:
		var rmin: Vector3 = rd["min"] as Vector3
		var rmax: Vector3 = rd["max"] as Vector3
		var rw := absf(rmax.x - rmin.x)
		var rl := absf(rmax.z - rmin.z)
		var rcx := (rmin.x + rmax.x) * 0.5
		var rcz := (rmin.z + rmax.z) * 0.5
		var road := MeshInstance3D.new()
		var rplane := PlaneMesh.new()
		rplane.size = Vector2(rw, rl)
		road.mesh = rplane
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = Color(0.16, 0.16, 0.17)
		rmat.roughness = 1.0
		road.material_override = rmat
		road.position = Vector3(rcx, 0.04, rcz)
		add_child(road)
		# Dashed centre line down the longer axis.
		var along_x := rw >= rl
		var span := rw if along_x else rl
		var dashes := int(span / 6.0)
		for di in dashes:
			var t := (float(di) + 0.5) / float(maxi(dashes, 1))
			var line := MeshInstance3D.new()
			var lmesh := BoxMesh.new()
			lmesh.size = Vector3(2.0, 0.02, 0.25) if along_x else Vector3(0.25, 0.02, 2.0)
			line.mesh = lmesh
			var lmat := StandardMaterial3D.new()
			lmat.albedo_color = Color(0.80, 0.72, 0.20)
			line.material_override = lmat
			if along_x:
				line.position = Vector3(rmin.x + t * rw, 0.06, rcz)
			else:
				line.position = Vector3(rcx, 0.06, rmin.z + t * rl)
			line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(line)

	# Capture point markers — a flat ground RING at the true capture radius (BattleBit zone read,
	# not a big solid disc that fills the screen at spawn) + a tall beacon so the point is a visible
	# landmark from across the map (flat terrain is otherwise impossible to navigate).
	for pt: Dictionary in map.points:
		var pt_pos: Vector3 = pt["pos"] as Vector3
		var pt_radius: float = pt["radius"] as float
		var marker := _make_ring_marker(pt_radius, 0.6, NEUTRAL_COLOR)
		marker.position = Vector3(pt_pos.x, 0.12, pt_pos.z)
		add_child(marker)
		var beacon := _make_box_mesh(Vector3(1.2, 30.0, 1.2), Color(0.95, 0.85, 0.25))
		beacon.position = Vector3(pt_pos.x, 15.0, pt_pos.z)
		add_child(beacon)

	# Base markers — team-coloured ground ring at the true base radius + a tall beacon.
	for b: Dictionary in map.bases:
		var b_team: int = b["team"] as int
		var b_pos: Vector3 = b["pos"] as Vector3
		var b_radius: float = b["radius"] as float
		var col: Color = TEAM_COLOR[b_team] if b_team < TEAM_COLOR.size() else NEUTRAL_COLOR
		var base_marker := _make_ring_marker(b_radius, 0.8, col)
		base_marker.position = Vector3(b_pos.x, 0.12, b_pos.z)
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

	# First-person weapon viewmodel — a default-AR GlbWeaponKit gun parented to the camera so it
	# tracks the view. (Per-weapon viewmodel needs client_main to pass WeaponPredictor.weapon — a
	# follow-up.) Placement/orientation (VM_OFFSET / VM_YAW) are playtest knobs.
	_viewmodel = build_viewmodel(Weapon.AR)
	_viewmodel_weapon = Weapon.AR
	_camera.add_child(_viewmodel)


## Hide/show the first-person viewmodel (photo/free-fly mode wants a clean frame with no gun).
func set_viewmodel_hidden(h: bool) -> void:
	if _viewmodel != null:
		_viewmodel.visible = not h

## Swap the first-person viewmodel to match the equipped weapon. Rebuilds only when the weapon id
## changes (so e.g. an RPG loadout shows the launcher, not the default AR). Call each frame.
func set_viewmodel_weapon(weapon_id: int) -> void:
	if weapon_id == _viewmodel_weapon or _camera == null:
		return
	var had_prev := _viewmodel != null
	_viewmodel_weapon = weapon_id
	if _viewmodel != null:
		_viewmodel.queue_free()
	_viewmodel = build_viewmodel(weapon_id)
	_camera.add_child(_viewmodel)
	if had_prev:
		play_viewmodel_swap(_now)   # the new weapon rises into view (skip the very first build)


## Start a melee-swing viewmodel animation (a quick forward bash/slash). Called when the player melees.
func play_viewmodel_swing(now: float) -> void:
	_vm_anim_kind = ViewmodelAnim.SWING
	_vm_anim_start = now
	_vm_anim_dur = ViewmodelAnim.SWING_DUR


## Start a weapon-swap viewmodel animation (the gun rises into view from lowered).
func play_viewmodel_swap(now: float) -> void:
	_vm_anim_kind = ViewmodelAnim.SWAP
	_vm_anim_start = now
	_vm_anim_dur = ViewmodelAnim.SWAP_DUR


## Start a recoil kick on the viewmodel (a sharp up/back jolt). Called on every shot fired; on
## full-auto each call restarts it from t=0 so the kick reads as a sustained jolt.
func play_viewmodel_recoil(now: float) -> void:
	_vm_anim_kind = ViewmodelAnim.RECOIL
	_vm_anim_start = now
	_vm_anim_dur = ViewmodelAnim.RECOIL_DUR


## Apply the active viewmodel animation offset on top of the base placement, each frame.
var _vm_loco_pos := Vector3.ZERO   # current locomotion offset (bob + eased sprint-lower)
var _vm_loco_rot := Vector3.ZERO
var _vm_sprint_t := 0.0            # 0..1 eased sprint-lower amount
var _vm_bob_phase := 0.0           # step cycle phase, advanced by distance travelled
var vm_sprint_test := false        # QA: force the sprint-lowered viewmodel for a screenshot

## Continuous viewmodel locomotion: a subtle walk bob + an eased sprint-lower, from the predicted
## pawn's motion. Composed in _pose_viewmodel on top of the base placement + any one-shot anim.
func _update_viewmodel_locomotion(pawn: Pawn, dt: float) -> void:
	if pawn == null:
		return
	var vel: Vector3 = pawn.velocity
	var speed := Vector2(vel.x, vel.z).length()
	var sprinting: bool = vm_sprint_test or (pawn.grounded and pawn.stance == Stance.STAND and speed > 6.5)
	var speed_norm := 1.0 if vm_sprint_test else clampf(speed / 6.0, 0.0, 1.0)
	_vm_sprint_t = lerpf(_vm_sprint_t, 1.0 if sprinting else 0.0, clampf(dt * 9.0, 0.0, 1.0))
	_vm_bob_phase = fmod(_vm_bob_phase + speed * dt * 1.7, TAU)
	var bob := ViewmodelAnim.walk_bob(speed_norm, _vm_bob_phase)
	_vm_loco_pos = (bob["pos"] as Vector3) + ViewmodelAnim.SPRINT_LOWER_POS * _vm_sprint_t
	_vm_loco_rot = (bob["rot"] as Vector3) + ViewmodelAnim.SPRINT_LOWER_ROT * _vm_sprint_t

func _pose_viewmodel(now: float) -> void:
	if _viewmodel == null:
		return
	var off := {"pos": Vector3.ZERO, "rot": Vector3.ZERO}
	if vm_swing_test:
		off = ViewmodelAnim.sample(ViewmodelAnim.SWING, 0.45)   # frozen mid-slash for the screenshot
	elif vm_recoil_test:
		off = ViewmodelAnim.sample(ViewmodelAnim.RECOIL, 0.1)    # frozen near the recoil peak for the screenshot
	elif _vm_anim_kind >= 0:
		var t := (now - _vm_anim_start) / _vm_anim_dur
		if t >= 1.0:
			_vm_anim_kind = -1   # done → back to rest
		else:
			off = ViewmodelAnim.sample(_vm_anim_kind, t)
	_viewmodel.position = VM_OFFSET + (off["pos"] as Vector3) + _vm_loco_pos
	_viewmodel.rotation = Vector3(0.0, VM_YAW, 0.0) + (off["rot"] as Vector3) + _vm_loco_rot


## First-person weapon viewmodel: a GlbWeaponKit weapon placed at the camera-space offset and yawed
## to face the camera's forward (-Z). Wraps the weapon in a holder so the kit's own orientation
## (MODEL_YAW) is preserved — placement composes, never clobbers. Static + geometry-only so it is
## unit-testable; setup() parents the result to the camera. Presentation-only (AGENTS.md §7).
static func build_viewmodel(weapon_id: int) -> Node3D:
	var holder := Node3D.new()
	holder.name = "Viewmodel"
	holder.position = VM_OFFSET
	holder.rotation = Vector3(0.0, VM_YAW, 0.0)
	holder.add_child(GlbWeaponKit.build(weapon_id))
	return holder


## Per-frame update. Safe to call with null world_view or predictor (early-returns).
func update(world_view: WorldView, predictor: Prediction, now: float, fov: float,
		look_yaw: float = 0.0, look_pitch: float = 0.0, eye: Vector3 = Vector3.INF,
		render_delta: float = 0.0) -> void:
	if world_view == null or predictor == null:
		return
	_now = now

	# 1. Entity pool update. Friend/foe is shown by a marker above friendlies (BattleBit-style),
	# not by body colour — so we need the local player's team. self_state() is the local pawn's
	# authoritative EntityState (null while dead/pre-spawn -> no friend markers that frame).
	var remotes: Dictionary = world_view.remotes_at(now)
	var self_es: EntityState = world_view.self_state()
	var local_team: int = self_es.team if self_es != null else -1
	_sync_entity_pool(remotes, local_team, render_delta, now)

	# 2. Structure pool update (pass world_view so the sync can drain COLLAPSE events for rubble)
	_sync_structure_pool(world_view, now)

	# 2b. Vehicle pool update (placeholder boxes so vehicles are visible + interactable).
	# Uses the real render-frame delta (not `now`, which only advances at the 30 Hz sim rate)
	# so smoothing runs per render frame.
	_sync_vehicle_pool(world_view.vehicles(), render_delta)

	# 3. Camera from prediction (position) + client look (rotation)
	_apply_camera(predictor, fov, look_yaw, look_pitch, eye)
	_update_viewmodel_locomotion(predictor.predicted, render_delta)
	_pose_viewmodel(now)   # apply any active swing/swap animation on top of the base placement

	# 4. Age out shot tracers + integrate cosmetic rockets + explosions
	_age_tracers(now)
	_age_flashes(now)
	_age_rockets(now, render_delta)
	_age_blasts(now)
	_age_debris(now, render_delta)
	_age_corpses(now)

	# 5. QA: armor-tier dummies (--armor-demo) + explosion pump (--boom-test) + corpses (--corpse-test)
	_ensure_armor_demo()
	_ensure_boom_demo(now)
	_ensure_corpse_demo(now)


## Visual QA (--armor-demo): once the camera exists, pin LIGHT/MEDIUM/HEAVY dummy soldiers in front
## of it (camera-parented, always in view) for a clean A/B/C armor-diff screenshot.
func _ensure_armor_demo() -> void:
	if not armor_demo or _armor_demo_done or _camera == null:
		return
	_armor_demo_done = true
	var tiers := [Armor.LIGHT, Armor.MEDIUM, Armor.HEAVY]
	var xs := [-2.5, 0.0, 2.5]
	for i in range(3):
		var dummy := CharacterKit.build()
		ArmorVisual.apply(dummy, tiers[i])
		dummy.position = Vector3(xs[i], -1.4, -7.0)   # camera-local: in front (-Z), lowered to show feet
		dummy.rotation = Vector3(0, PI, 0)            # face the camera
		_camera.add_child(dummy)


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


## Launch a cosmetic RPG rocket from origin along dir: a muzzle flash + a flying rocket that arcs via
## the shared Grenade ballistic model (matching the server) and trails smoke until it hits / expires.
func fire_rocket(origin: Vector3, dir: Vector3, now: float) -> void:
	var d := dir.normalized()
	if d.length() < 0.001:
		return
	var node := _make_rocket()
	var up := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	node.global_transform = Transform3D(Basis.looking_at(d, up), origin)
	add_child(node)
	_spawn_flash(origin, d, now)   # launch flash
	_rockets.append({"node": node, "vel": d * ROCKET_SPEED, "die": now + ROCKET_LIFETIME, "next_puff": now})


func _age_rockets(now: float, delta: float) -> void:
	if not _rockets.is_empty():
		var live: Array = []
		for r: Dictionary in _rockets:
			var node: Node3D = r["node"]
			var s := Grenade.integrate(node.position, r["vel"], delta)
			var npos: Vector3 = s["pos"]
			var nvel: Vector3 = s["vel"]
			if now >= float(r["next_puff"]):
				_spawn_puff(node.position, 0.4, 0.6, now)   # trail
				r["next_puff"] = now + ROCKET_TRAIL_DT
			if now >= float(r["die"]) or npos.y <= 0.0:
				if npos.y < 0.0:
					npos.y = 0.0
				_spawn_puff(npos, 2.4, 0.55, now)           # impact puff
				node.queue_free()
				continue
			var up := Vector3.UP if absf(nvel.normalized().dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
			node.global_transform = Transform3D(Basis.looking_at(nvel.normalized(), up), npos)
			r["vel"] = nvel
			live.append(r)
		_rockets = live
	_age_puffs(now)


func _make_rocket() -> Node3D:
	# Forward = local -Z (Basis.looking_at convention), so the warhead sits at -Z.
	var root := Node3D.new()
	root.name = "Rocket"
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.15, 0.15, 0.17); dark.metallic = 0.3; dark.roughness = 0.6
	var body := MeshInstance3D.new()
	var bmesh := BoxMesh.new(); bmesh.size = Vector3(0.16, 0.16, 0.6)
	body.mesh = bmesh; body.material_override = dark
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(body)
	var nose := MeshInstance3D.new()
	var nmesh := BoxMesh.new(); nmesh.size = Vector3(0.2, 0.2, 0.2)
	nose.mesh = nmesh; nose.position = Vector3(0, 0, -0.36)
	var nmat := StandardMaterial3D.new()
	nmat.albedo_color = Color(0.7, 0.5, 0.18); nmat.emission_enabled = true
	nmat.emission = Color(0.6, 0.35, 0.12); nmat.emission_energy_multiplier = 0.6
	nose.material_override = nmat; nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(nose)
	for ang in [0.0, PI * 0.5]:   # tail fins
		var fin := MeshInstance3D.new()
		var fmesh := BoxMesh.new(); fmesh.size = Vector3(0.36, 0.02, 0.16)
		fin.mesh = fmesh; fin.position = Vector3(0, 0, 0.28); fin.rotation = Vector3(0, 0, ang)
		fin.material_override = dark; fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(fin)
	return root


func _spawn_puff(pos: Vector3, size: float, ttl: float, now: float) -> void:
	var node := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = size * 0.5; sm.height = size; sm.radial_segments = 6; sm.rings = 3
	node.mesh = sm
	node.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.55, 0.65)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_puffs.append({"node": node, "mat": mat, "die": now + ttl, "ttl": ttl})


func _age_puffs(now: float) -> void:
	if _puffs.is_empty():
		return
	var live: Array = []
	for p: Dictionary in _puffs:
		var remaining: float = float(p["die"]) - now
		if remaining <= 0.0:
			(p["node"] as Node3D).queue_free()
			continue
		var frac := remaining / float(p["ttl"])
		var mat: StandardMaterial3D = p["mat"]
		var c := mat.albedo_color; c.a = clampf(frac * 0.65, 0.0, 0.65); mat.albedo_color = c
		var grow := 1.0 + (1.0 - frac) * 1.3
		(p["node"] as Node3D).scale = Vector3(grow, grow, grow)
		live.append(p)
	_puffs = live


# =============================================================================
#  Explosion VFX (M7) — driven by the server DETONATION event (cosmetic).
# =============================================================================
const BLAST_TTL := 0.45        # frag fireball lifetime (s)
const FLASH_BLAST_TTL := 0.28  # flashbang white pop lifetime (s)
const DEBRIS_TTL := 0.7
const DEBRIS_GRAVITY := 18.0

## Spawn a cosmetic explosion at pos. kind: Protocol.DET_EXPLOSION (orange fireball + smoke + debris)
## or Protocol.DET_FLASH (bright white pop). Called from client_main on a DETONATION packet.
func spawn_explosion(pos: Vector3, kind: int, now: float) -> void:
	if not pos.is_finite():
		return
	if kind == 1:   # Protocol.DET_FLASH
		_spawn_blast(pos + Vector3(0, 0.6, 0), Color(1.0, 1.0, 1.0), 1.2, 6.0, FLASH_BLAST_TTL, now)
		return
	# frag / impact: a fireball core + an expanding smoke puff + scattered debris
	_spawn_blast(pos + Vector3(0, 0.6, 0), Color(1.0, 0.62, 0.18), 0.8, 4.2, BLAST_TTL, now)
	_spawn_puff(pos + Vector3(0, 0.7, 0), 2.8, 0.75, now)
	_spawn_debris(pos + Vector3(0, 0.3, 0), now)


## An emissive sphere that expands start_size -> end_size and fades over ttl. Unshaded so it reads as
## a self-lit flash regardless of scene lighting.
func _spawn_blast(pos: Vector3, color: Color, start_size: float, end_size: float, ttl: float, now: float) -> void:
	var node := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = 0.5; sm.height = 1.0; sm.radial_segments = 8; sm.rings = 4
	node.mesh = sm
	node.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.5
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_blasts.append({"node": node, "mat": mat, "born": now, "die": now + ttl, "ttl": ttl,
		"s0": start_size, "s1": end_size, "color": color})


func _age_blasts(now: float) -> void:
	if _blasts.is_empty():
		return
	var live: Array = []
	for b: Dictionary in _blasts:
		var remaining: float = float(b["die"]) - now
		if remaining <= 0.0:
			(b["node"] as Node3D).queue_free()
			continue
		var t := 1.0 - remaining / float(b["ttl"])   # 0 -> 1 over life
		var size: float = lerpf(float(b["s0"]), float(b["s1"]), sqrt(t))   # fast initial expansion
		(b["node"] as Node3D).scale = Vector3(size, size, size)
		var mat: StandardMaterial3D = b["mat"]
		var c: Color = b["color"]; c.a = clampf(1.0 - t, 0.0, 1.0); mat.albedo_color = c
		mat.emission_energy_multiplier = 2.5 * (1.0 - t)
		live.append(b)
	_blasts = live


func _spawn_debris(pos: Vector3, now: float) -> void:
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.18, 0.16, 0.14)
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in range(7):
		var node := MeshInstance3D.new()
		var bmesh := BoxMesh.new(); bmesh.size = Vector3(0.12, 0.12, 0.12)
		node.mesh = bmesh; node.position = pos; node.material_override = dark
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		# Fan outward + up; vary by index so each piece flies differently (no per-frame RNG).
		var ang := TAU * float(i) / 7.0
		var vel := Vector3(cos(ang) * 5.0, 6.0 + float(i % 3) * 1.5, sin(ang) * 5.0)
		_debris.append({"node": node, "vel": vel, "die": now + DEBRIS_TTL})


func _age_debris(now: float, delta: float) -> void:
	if _debris.is_empty():
		return
	var dt := clampf(delta, 0.0, 0.1)   # ignore absurd startup/stall deltas so debris can't fling to INF
	var live: Array = []
	for d: Dictionary in _debris:
		if now >= float(d["die"]):
			(d["node"] as Node3D).queue_free()
			continue
		var node: Node3D = d["node"]
		var vel: Vector3 = d["vel"]
		vel.y -= DEBRIS_GRAVITY * dt
		var npos := node.position + vel * dt
		if npos.y < 0.0:
			npos.y = 0.0; vel = Vector3.ZERO   # settle on the ground
		node.position = npos
		d["vel"] = vel
		live.append(d)
	_debris = live


## Visual QA (--boom-test): pump frag explosions in front of the camera so a screenshot always
## catches a fireball + debris + smoke at some age.
func _ensure_boom_demo(now: float) -> void:
	if not boom_demo or _camera == null or now < _boom_next:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return   # camera not positioned yet (pre-deploy) — don't spawn at INF
	_boom_next = now + 0.28
	_boom_i += 1
	var fwd := (-cb.basis.z).normalized()
	var lateral := cb.basis.x * (float((_boom_i % 3) - 1) * 2.2)
	spawn_explosion(cb.origin + fwd * 8.0 + lateral - Vector3(0, 1.0, 0), 0, now)


# =============================================================================
#  Entity pool helpers (CharacterKit soldiers)
# =============================================================================

func _sync_entity_pool(remotes: Dictionary, local_team: int, render_delta: float, now: float) -> void:
	# Release nodes for ids that are gone or dead (and their friend markers). An entity that is still
	# in view but just went `not alive` DIED here (vs. one that simply left interest) — drop a corpse
	# at its last pose before releasing. This fires exactly once: _release_entity drops it from _active
	# and the acquire loop skips dead ids, so a dead-but-in-view pawn is never re-processed.
	var to_release: Array = []
	for id: int in _active:
		if not remotes.has(id):
			to_release.append(id)
		else:
			var es: EntityState = remotes[id] as EntityState
			if not es.alive:
				_spawn_corpse(es, now)
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


## Lay a dead body at a pawn's last pose (face-DOWN, so a corpse reads differently from a face-UP
## downed/DBNO teammate). Honors the armor tier so the corpse matches how the pawn looked alive.
## Always procedural (CharacterKit), even in GLB mode: a static GLB has no AnimationPlayer driving a
## clip, so it renders collapsed/invisible — a blocky fallen body is the reliable corpse representation.
func _spawn_corpse(es: EntityState, now: float) -> void:
	if not es.pos.is_finite():
		return
	var node := CharacterKit.build()   # no LOD: corpses are capped + short-lived, and the proxy/range cull hid them
	ArmorVisual.apply(node, es.armor_class)
	var b := Basis.IDENTITY.rotated(Vector3.UP, es.yaw)
	b = b.rotated(b.x, PI * 0.5)   # face-down on the ground (downed bodies lie face-up; corpses don't)
	node.transform.basis = b
	node.scale = Vector3.ONE
	node.position = Vector3(es.pos.x, es.pos.y + PRONE_LIFT, es.pos.z)
	add_child(node)
	_corpses.append({"node": node, "die": now + CORPSE_TTL, "y0": node.position.y})
	if _corpses.size() > CORPSE_MAX:
		var oldest: Dictionary = _corpses.pop_front()
		(oldest["node"] as Node3D).queue_free()


func _age_corpses(now: float) -> void:
	if _corpses.is_empty():
		return
	var live: Array = []
	for cps: Dictionary in _corpses:
		var remaining: float = float(cps["die"]) - now
		var node: Node3D = cps["node"]
		if remaining <= 0.0:
			node.queue_free()
			continue
		if remaining < CORPSE_FADE:
			# sink into the ground over the final second instead of popping out
			var sunk := (1.0 - remaining / CORPSE_FADE) * 1.2
			node.position.y = float(cps["y0"]) - sunk
		live.append(cps)
	_corpses = live


## Visual QA (--corpse-test): lay a few corpses CAMERA-PARENTED in front of the view so a screenshot
## always catches them regardless of spawn point / map occluders. Same mesh + flat-lay pose as a real
## corpse; only the placement is camera-relative (the real _spawn_corpse is world-positioned at deaths).
func _ensure_corpse_demo(now: float) -> void:
	if not corpse_demo or _corpse_demo_done or _camera == null or now < 3.0:
		return
	_corpse_demo_done = true
	var tiers := [Armor.LIGHT, Armor.MEDIUM, Armor.HEAVY]
	for i in range(3):
		var node := CharacterKit.build()
		ArmorVisual.apply(node, tiers[i])
		# Tipped ~70° onto their backs (clearly a fallen body, with enough vertical extent to read in a
		# screenshot — a full 90° flat body is a thin sliver at a grazing angle). The real _spawn_corpse
		# lays them fully flat at the death spot; this is only the QA framing.
		var b := Basis.IDENTITY.rotated(Vector3.UP, float(i) * 0.5)
		b = b.rotated(b.x, PI * 0.42)
		node.transform.basis = b
		node.position = Vector3(float(i - 1) * 2.0, -1.6, -5.5)
		_camera.add_child(node)
		_corpses.append({"node": node, "die": now + CORPSE_TTL + float(i) * 30.0, "y0": node.position.y})


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
	_last_speed.erase(id)
	_armor_tier.erase(id)
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
	# Armor-tier vest/helmet (M5.5-P2). Re-apply only when this (pooled) node's tier changes — a node
	# recycled from the free list may still carry the previous id's tier. Cheap + before any return.
	if _armor_tier.get(id, -1) != es.armor_class:
		ArmorVisual.apply(node, es.armor_class)
		_armor_tier[id] = es.armor_class
	if use_models:
		# Horizontal speed estimate from frame-to-frame position (velocity isn't replicated).
		# The interpolated position only advances on SIM ticks (`now` steps at 30 Hz), so dividing by
		# the render delta read 0 on inter-tick frames and ~2x on tick frames — strobing the idle/walk
		# clip ("4 hands"). Divide by the sim step (the real interval between position updates) and HOLD
		# the last speed on frames where the position didn't change.
		var last: Vector3 = _last_pos.get(id, es.pos)
		var flat := Vector3(es.pos.x - last.x, 0.0, es.pos.z - last.z)
		var speed: float = _last_speed.get(id, 0.0)
		if flat.length() > 0.0001:
			speed = minf(flat.length() / SimLoop.DT, 20.0)   # 20 m/s cap: a respawn/teleport jump can't read as a sprint
			_last_speed[id] = speed
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

func _sync_structure_pool(world_view: WorldView, now: float) -> void:
	# Tick dying pops — release when their tween has finished (tracked by die time). Cheap and
	# tween-driven, so it runs every frame regardless of whether the structure set changed.
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

	# M11: drain collapse events — each fully-collapsed building swaps to a rubble marker. Must run
	# every frame (the queue is normally empty; a collapse also bumps the version below).
	for bid_v: Variant in world_view.take_collapsed():
		_spawn_rubble_for(int(bid_v))

	# Structures are static once placed — only walk the (large) pool when the store actually changed
	# (build/destroy/damage/collapse). The steady state is a no-op, which is what makes a 77-building
	# map render at full rate instead of re-posing thousands of static pieces every frame.
	var ver: int = world_view.structs_version()
	if ver == _struct_synced_ver:
		return
	_struct_synced_ver = ver
	var structs: Dictionary = world_view.structures()

	# Release nodes for ids that have been removed from the store
	var to_release: Array = []
	for id: int in _struct_active:
		if not structs.has(id):
			to_release.append(id)
	for id: int in to_release:
		_start_destroy_pop(id, now)

	# Acquire / update nodes for all known structures. _pose_structure only needs to run when a node
	# is newly created or rebuilt (geometry/tint is baked at build) — static pieces keep their pose.
	for id_v: Variant in structs:
		var id: int = int(id_v)
		var rec: Dictionary = structs[id_v]
		var was_present := _struct_active.has(id)
		var node: Node3D = _acquire_structure(id, rec)
		if not was_present or _struct_rebuilt:
			_pose_structure(node, rec)
			# M11: track a per-building centroid (last-posed piece position is fine for a placeholder
			# rubble marker) so a COLLAPSE can drop rubble where the building stood.
			var bid: int = int(rec.get("building_id", 0))
			if bid != 0:
				_building_centroid[bid] = node.position
		# Pop only on a genuinely new structure, not on a damage-driven rebuild (still present).
		if not was_present:
			_start_build_pop(node)


func _acquire_structure(id: int, rec: Dictionary) -> Node3D:
	var key := _struct_key(rec)
	if _struct_active.has(id):
		if String(_struct_key_of.get(id, "")) == key:
			_struct_rebuilt = false
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
	_struct_rebuilt = true
	return node


func _struct_key(rec: Dictionary) -> String:
	var type_idx := int(rec.get("type", 0))
	return "%d:%d" % [type_idx, _bucket_of(rec)]


## Damage tier (3 pristine .. 0 heavy) for a structure record. M11 dropped the M4 `bucket` field and
## now ships a per-face chunk alive-mask (`chunks`); the StructureKit still skins by tier, so we
## quantise the fraction of intact chunks. Missing/all-bits mask reads pristine (defensive default).
func _bucket_of(rec: Dictionary) -> int:
	return WorldRenderer.damage_bucket(int(rec.get("chunks", -1)), _grid_of(int(rec.get("type", 0))))


static func _grid_of(type_idx: int) -> int:
	return STRUCT_TYPE_GRID[type_idx] if type_idx >= 0 and type_idx < STRUCT_TYPE_GRID.size() else 8


## Map a chunk alive-mask to a StructureKit damage bucket. Full mask -> 3 (pristine); fewer intact
## chunks step down through 2 and 1; near-empty -> 0 (chipped silhouette). A piece is removed from the
## store entirely once its mask hits 0, so the renderer only ever skins live (alive > 0) pieces.
static func damage_bucket(chunks: int, grid: int) -> int:
	var total := ChunkMask.count(grid)
	var alive := ChunkMask.popcount(chunks)
	if alive >= total:
		return 3
	var frac := float(alive) / float(total)
	if frac > 0.66:
		return 2
	if frac > 0.33:
		return 1
	return 0


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
	# Lift the whole building a hair onto a foundation so the ground-floor slab doesn't z-fight /
	# poke through the grass plane (both were at y=0). Imperceptible step at the door.
	node.position = Vector3(float(cell.x) * BuildGrid.CELL_SIZE + half,
							float(cell.y) * BuildGrid.CELL_SIZE + STRUCT_LIFT,
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
	# M11: building piece ids ("b*") + interior props ("prop_*") come from BuildingKit; player-built
	# fortifications (wall/sandbag) from StructureKit. NOTE: StructureKit only knows wall/sandbag, so
	# every prop except prop_crate used to fall through to a 2.4 m concrete WALL — route all prop_* here.
	if piece_id.begins_with("b") or piece_id.begins_with("prop_"):
		# Ground-floor perimeter walls/columns + interior props carry a floor-skirt slab so the deck
		# reaches the walls and props sit on a floor (closes the floor-to-wall gap + the under-prop gap).
		# Only at the ground deck (cell.y == 0) — upper solid-wall bands have no walkable deck, so a skirt
		# there would float inside the building.
		var cell: Vector3i = rec["cell"] as Vector3i
		var skirt := cell.y == 0 and (piece_id.begins_with("bwall") or piece_id == "bcolumn" \
			or piece_id.begins_with("prop_"))
		return BuildingKit.build(piece_id, _bucket_of(rec), skirt)
	return StructureKit.build(piece_id, _bucket_of(rec))


## M11: replace a collapsed building with a flat rubble marker at its last-known centroid.
func _spawn_rubble_for(building_id: int) -> void:
	if not _building_centroid.has(building_id):
		return   # unknown / double-collapse — don't dump rubble at world origin
	var center: Vector3 = _building_centroid[building_id]
	var rubble := BuildingKit.build_rubble()
	rubble.position = center
	add_child(rubble)
	_building_centroid.erase(building_id)


## A flat ground ring (TorusMesh lies in the XZ plane) marking a zone boundary at `radius`, with a
## `tube`-thick band. Emissive + semi-transparent + unshaded so it glows as a marker at any range and
## reads cleanly over the terrain without filling the view like the old solid disc did.
func _make_ring_marker(radius: float, tube: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = maxf(radius - tube, 0.1)
	mesh.outer_radius = radius + tube
	mesh.rings = 48          # smooth circle around the zone
	mesh.ring_segments = 6   # cheap tube cross-section (it's flat on the ground)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.55)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.3
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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

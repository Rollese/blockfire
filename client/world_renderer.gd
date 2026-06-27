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
const VM_ADS_OFFSET := Vector3(0.05, -0.20, -0.34)  # ADS: pull the gun inboard + low so it braces under the (zoomed) sightline without filling the view
const VM_YAW := PI   # GlbWeaponKit aims the barrel +Z; camera-forward is -Z, so flip 180° to aim with the view
var _ads_t := 0.0   # 0..1 aim-down-sights blend (client-only visual zoom/pose); set each frame by client_main
var _vm_photo_hidden := false   # viewmodel hidden by photo/free-fly mode
var _vm_scope_hidden := false   # viewmodel hidden while scoped (look through the scope, not at the gun)

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
# thrown-grenade cosmetics (M7, view-only): the local thrower sees their own frag/smoke fly the
# shared Grenade ballistic arc (matching the server's eye-origin + launch_velocity) and vanish on
# ground contact or at the 1.5 s fuse — the DETONATION / SMOKE_DEPLOYED event then plays the effect.
const GRENADE_FUSE := 1.5         # s — MUST match server GRENADE_FUSE_TICKS (45 @ 30 Hz)
const GRENADE_TRAIL_DT := 0.05    # s between a smoke grenade's faint trail puffs
var _thrown: Array = []           # [{node:Node3D, vel:Vector3, die:float, kind:int, next_trail:float}]
var _puffs: Array = []            # [{node, mat, die, ttl}] — smoke trail + impact puffs
var _blasts: Array = []           # [{node, mat, born, die, ttl, s0, s1, color}] — explosion fireball cores
var _debris: Array = []           # [{node, vel, die}] — explosion debris chunks
var _casings: Array = []          # [{node, vel, spin, die}] — ejected brass shell casings (local gun)
var _casing_i := 0                # rotates per-shot variation without per-frame RNG
var _casing_mat: StandardMaterial3D = null
# smoke-grenade clouds (M7, view-only): SMOKE_DEPLOYED -> a cluster of soft puffs filling the zone
# radius, opacity following SmokeCloud.envelope (billow-in / hold / fade-out). Bounded for 128p.
const SMOKE_MAX_CLOUDS := 24      # cap concurrent client clouds (drop oldest); bounds mesh count
const SMOKE_PUFFS := 16           # soft spheres per cloud (overlap into a near-solid mass)
const SMOKE_BASE_ALPHA := 0.86    # peak per-puff opacity (x SmokeCloud.envelope)
const SMOKE_COLOR := Color(0.84, 0.85, 0.87)   # light cool grey
var _smokes: Array = []           # [{root:Node3D, mats:Array, born:float, dur:float, base:Array}]
var smoke_demo := false           # --smoke-test: pop a smoke cloud in front of the camera (QA)
var _smoke_demo_next := 0.0       # re-pop cadence (so a cloud lands in front AFTER the player deploys)
var grenade_demo := false         # --grenade-test: lob cosmetic grenades across the view (QA)
var _grenade_demo_next := 0.0
var _grenade_demo_i := 0
# deployed gadgets (M7, view-only): the server broadcasts an authoritative GADGET_LIST (C4/mine/bag);
# set_gadgets replaces the rendered set on each receipt, so the client always mirrors true server state.
var _gadget_nodes: Array = []     # current gadget mesh roots (freed + rebuilt on each set_gadgets)
var gadget_demo := false          # --gadget-test: place sample gadgets in front of the camera (QA)
var _gadget_demo_next := 0.0
var revive_demo := false          # --revive-marker-test: a downed friendly + revive marker in view (QA)
var _revive_demo_marker: MeshInstance3D = null
var boom_demo := false            # --boom-test: pump frag explosions in front of the camera (QA)
var _boom_next := 0.0
var _boom_i := 0
var wreck_demo := false           # --vehicle-test: blow up a transport in front of the camera (QA)
var _wreck_demo_done := false
var casing_demo := false          # --casing-test: pump shell casings from the gun port (QA)
var _casing_demo_next := 0.0
var impact_demo := false          # --impact-test: pump bullet impacts in front of the camera (QA)
var _impact_next := 0.0
var _impact_i := 0
# footstep feedback (view-only, AGENTS.md §7): a moving grounded pawn fires a footstep every stride
# of ground travel -> a small dust puff (remotes) + a spatial footstep sound (via the `footstep`
# signal, which client_main routes to the AudioDirector). Cadence math lives in FootstepCadence.
signal footstep(world_pos: Vector3, intensity: float)
signal impact(world_pos: Vector3, kind: int)   # a bullet terminated in the world (wall/dirt/flesh)
const FOOTSTEP_DUST_COLOR := Color(0.58, 0.54, 0.46, 0.4)   # faint tan scuff, lighter than an impact puff
const FOOTSTEP_PUFF_TTL := 0.4    # s the kicked-up dust lingers
var _step_accum: Dictionary = {}  # id(int) -> float: stride-distance accumulator per remote
var _step_prev: Dictionary = {}   # id(int) -> Vector3: last position a footstep tick saw (per remote)
var _local_step_accum: float = 0.0
# airborne inference (view-only): remotes carry no `grounded` on the wire, so estimate vertical
# velocity from interpolated-y deltas to drive a jump/fall pose + a landing dust burst.
var _air_y: Dictionary = {}       # id -> last y seen
var _air_vy: Dictionary = {}      # id -> smoothed vertical velocity (units/s)
var _air_fell: Dictionary = {}    # id -> bool: fell fast enough to kick dust on landing
var _vm_land_dip := 0.0           # local viewmodel land-dip offset (m), decays each frame
const AIR_JUMP_VY := 2.2          # |vy| above this reads as airborne (jump/fall pose)
const AIR_FALL_VY := 3.5          # falling faster than this arms a landing dust burst
const AIR_LAND_VY := 1.0          # settle below this = grounded again
const JUMP_PITCH := 0.20          # rad forward lean of an airborne figure
const JUMP_TUCK := 0.88           # vertical scale of an airborne figure (mild tuck = off the ground)
const MAX_LAND_DIP := 0.09        # local viewmodel dip on a hard landing (m)
const LAND_DIP_DECAY := 8.0       # per-second ease of the land dip back to rest
var footstep_demo := false        # --footstep-test: pump footstep dust at ground in front of camera (QA)
var _footstep_next := 0.0

# corpse-on-death: a body left where a pawn died (alive->false in view), lingering then despawning.
const CORPSE_TTL := 14.0          # seconds a corpse lingers before despawn
const CORPSE_FADE := 1.0          # seconds of sink-into-ground at the end of life
const CORPSE_MAX := 40            # cap; oldest is removed when exceeded (bounds cost at fleet density)
var _corpses: Array = []          # [{node: Node3D, die: float, y0: float}]
var corpse_demo := false          # --corpse-test: lay a few corpses in front of the camera (QA)
var _corpse_demo_done := false
var climb_demo := false           # --climb-test: pin a climbing-posed dummy beside an upright one (QA)
var _climb_demo_done := false
var jump_demo := false            # --jump-test: pin an airborne-posed dummy beside an upright one (QA)
var _jump_demo_done := false
var land_demo := false            # --land-test: pump landing dust + viewmodel dip (QA)
var _land_demo_next := 0.0

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

# active structure nodes: id(int) -> Node3D (StructureKit piece) — legacy per-piece path, now only
# freed on the first batched rebuild; rendering is via _struct_batches below.
var _struct_active: Dictionary = {}
# Batched structure render: MultiMeshInstance3D per (piece visual key, mesh slot). Rebuilt on change.
var _struct_batches: Array = []
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
const REVIVE_MARKER_COLOR := Color(1.0, 0.32, 0.22)   # downed teammate (needs revive) — stands out from blue
const PRONE_LIFT := 0.3          # small lift so a flat-lying prone/downed body rests on the ground
const CLIMB_PITCH := 0.32        # rad (~18°) forward lean of a figure climbing a ladder (vs. bolt-upright)
# active vehicle nodes: vid(int) -> Node3D (VehicleKit transport; VehicleState carries no team)
var _vehicle_active: Dictionary = {}
var _vehicle_free_list: Array = []
const VEHICLE_SMOOTH_RATE := 16.0                # higher = snappier; ~1/e catch-up in ~60 ms
var _wreck_mat: StandardMaterial3D = null        # shared burnt-out material for destroyed vehicles
const _WRECK_DEMO_VID := -424242                 # synthetic vid for the --vehicle-test wreck
const _DMG_DEMO_VID := -424243                   # synthetic vid for the --vehicle-test damaged transport
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
var vm_reload_test := false       # --reload-test: hold the viewmodel mid-reload for a QA screenshot


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
	_vm_photo_hidden = h
	_apply_vm_visibility()

## Hide the viewmodel while scoped — you look *through* the scope, not at the gun (the centred gun
## would otherwise fill the scope circle). Composes with the photo-mode hide.
func set_viewmodel_scope_hidden(h: bool) -> void:
	_vm_scope_hidden = h
	_apply_vm_visibility()

func _apply_vm_visibility() -> void:
	if _viewmodel != null:
		_viewmodel.visible = not (_vm_photo_hidden or _vm_scope_hidden)

## Aim-down-sights blend (0 = hip, 1 = fully aimed). Client-only visual: shifts the viewmodel to the
## sight line (see _pose_viewmodel) and damps the locomotion bob. The matching FOV zoom is applied by
## client_main (it owns the per-weapon FOV). View-only (AGENTS.md §7).
func set_ads(t: float) -> void:
	_ads_t = clampf(t, 0.0, 1.0)

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


## Start a reload viewmodel animation stretched over the actual per-weapon reload time (`dur` secs)
## so the gesture lasts exactly as long as the predicted reload.
func play_viewmodel_reload(now: float, dur: float) -> void:
	_vm_anim_kind = ViewmodelAnim.RELOAD
	_vm_anim_start = now
	_vm_anim_dur = maxf(dur, 0.2)


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
const SPRINT_FOV_ADD := 8.0        # degrees of FOV widening at full sprint (eased via _vm_sprint_t)

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
	# Land dip: a quick downward kick on touchdown that eases back to rest (set by play_land_dip).
	_vm_land_dip = lerpf(_vm_land_dip, 0.0, clampf(dt * LAND_DIP_DECAY, 0.0, 1.0))
	_vm_loco_pos.y -= _vm_land_dip

func _pose_viewmodel(now: float) -> void:
	if _viewmodel == null:
		return
	var off := {"pos": Vector3.ZERO, "rot": Vector3.ZERO}
	if vm_swing_test:
		off = ViewmodelAnim.sample(ViewmodelAnim.SWING, 0.45)   # frozen mid-slash for the screenshot
	elif vm_recoil_test:
		off = ViewmodelAnim.sample(ViewmodelAnim.RECOIL, 0.1)    # frozen near the recoil peak for the screenshot
	elif vm_reload_test:
		off = ViewmodelAnim.sample(ViewmodelAnim.RELOAD, 0.5)    # frozen mid-reload for the screenshot
	elif _vm_anim_kind >= 0:
		var t := (now - _vm_anim_start) / _vm_anim_dur
		if t >= 1.0:
			_vm_anim_kind = -1   # done → back to rest
		else:
			off = ViewmodelAnim.sample(_vm_anim_kind, t)
	# ADS pulls the gun to the sight line and damps the locomotion bob (you hold steadier when aiming).
	var base_pos: Vector3 = VM_OFFSET.lerp(VM_ADS_OFFSET, _ads_t)
	var loco_damp: float = 1.0 - 0.85 * _ads_t
	_viewmodel.position = base_pos + (off["pos"] as Vector3) + _vm_loco_pos * loco_damp
	_viewmodel.rotation = Vector3(0.0, VM_YAW, 0.0) + (off["rot"] as Vector3) + _vm_loco_rot * loco_damp


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
	_update_viewmodel_locomotion(predictor.predicted, render_delta)   # eases _vm_sprint_t (camera FOV + pose read it)
	_tick_local_footstep(predictor.predicted, render_delta, eye, now)   # local footstep audio (no dust)
	_apply_camera(predictor, fov, look_yaw, look_pitch, eye)
	_pose_viewmodel(now)   # apply any active swing/swap animation on top of the base placement

	# 4. Age out shot tracers + integrate cosmetic rockets + explosions
	_age_tracers(now)
	_age_flashes(now)
	_age_rockets(now, render_delta)
	_age_blasts(now)
	_age_debris(now, render_delta)
	_age_casings(now, render_delta)
	_age_corpses(now)
	_age_smokes(now)
	_age_thrown(now, render_delta)

	# 5. QA: armor-tier dummies (--armor-demo) + explosion pump (--boom-test) + corpses (--corpse-test)
	_ensure_armor_demo()
	_ensure_boom_demo(now)
	_ensure_impact_demo(now)
	_ensure_corpse_demo(now)
	_ensure_footstep_demo(now)
	_ensure_smoke_demo(now)
	_ensure_grenade_demo(now)
	_ensure_gadget_demo(now)
	_ensure_revive_demo(now)
	_ensure_wreck_demo(now)
	_ensure_casing_demo(now)
	_ensure_climb_demo(now)
	_ensure_jump_demo(now)
	_ensure_land_demo(now)


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


# =============================================================================
#  Thrown grenade cosmetics (M7) — local thrower feedback for frag/smoke.
# =============================================================================

## Spawn a cosmetic thrown grenade arcing from `origin` with initial `vel` (use Grenade.launch_velocity
## from the look dir, matching the server). `kind` is Grenade.FRAG / Grenade.SMOKE — only the colour
## differs. It flies the shared ballistic arc and vanishes on ground contact or at the fuse; the
## server's DETONATION / SMOKE_DEPLOYED then plays the blast / cloud at the landing point.
func throw_grenade(origin: Vector3, vel: Vector3, kind: int, now: float) -> void:
	if not origin.is_finite() or not vel.is_finite():
		return
	var node := _make_grenade(kind)
	node.position = origin
	add_child(node)
	_thrown.append({"node": node, "vel": vel, "die": now + GRENADE_FUSE, "kind": kind, "next_trail": now})


func _age_thrown(now: float, delta: float) -> void:
	if _thrown.is_empty():
		return
	var live: Array = []
	for g: Dictionary in _thrown:
		var node: Node3D = g["node"]
		var s := Grenade.integrate(node.position, g["vel"], delta)
		var npos: Vector3 = s["pos"]
		g["vel"] = s["vel"]
		# a smoke canister leaks a faint trail so the throw reads in the air
		if int(g["kind"]) == Grenade.SMOKE and now >= float(g["next_trail"]):
			_spawn_puff(node.position, 0.3, 0.45, now, Color(0.78, 0.80, 0.80, 0.4))
			g["next_trail"] = now + GRENADE_TRAIL_DT
		if now >= float(g["die"]) or npos.y <= 0.0:
			node.queue_free()   # detonation/smoke event plays the end effect at the landing point
			continue
		node.position = npos
		node.rotate_x(delta * 9.0)   # tumble in flight
		live.append(g)
	_thrown = live


## World positions of the live cosmetic grenades (local throws + remote GRENADE_FX). The HUD reads
## this to warn when one is about to go off near the player. View-only — no gameplay authority.
func live_grenade_positions() -> Array:
	var out: Array = []
	for g: Dictionary in _thrown:
		out.append((g["node"] as Node3D).position)
	return out


func _make_grenade(kind: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Grenade"
	var body := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = 0.11; sm.height = 0.30; sm.radial_segments = 8; sm.rings = 5
	body.mesh = sm
	var mat := StandardMaterial3D.new()
	# frag = dark olive, smoke = grey-green canister
	mat.albedo_color = Color(0.20, 0.24, 0.12) if kind == Grenade.FRAG else Color(0.30, 0.40, 0.34)
	mat.metallic = 0.2; mat.roughness = 0.7
	body.material_override = mat
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(body)
	return root




func _spawn_puff(pos: Vector3, size: float, ttl: float, now: float, color := Color(0.55, 0.55, 0.55, 0.65)) -> void:
	var node := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = size * 0.5; sm.height = size; sm.radial_segments = 6; sm.rings = 3
	node.mesh = sm
	node.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
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
#  Smoke-grenade clouds (M7) — driven by SMOKE_DEPLOYED (cosmetic, view-only).
# =============================================================================

## Pop a smoke cloud filling a `radius` zone at `pos`, living `duration` seconds. Builds a cluster of
## soft unshaded puffs scattered in the zone; opacity is driven per-frame by SmokeCloud.envelope in
## _age_smokes (billow-in / hold / fade-out). Deterministic offsets (golden-angle spiral) so the
## cloud reads the same every time; capped at SMOKE_MAX_CLOUDS (oldest dropped) to bound mesh count.
func spawn_smoke(pos: Vector3, radius: float, duration: float, now: float) -> void:
	if not pos.is_finite() or radius <= 0.0 or duration <= 0.0:
		return
	while _smokes.size() >= SMOKE_MAX_CLOUDS:
		var oldest: Dictionary = _smokes.pop_front()
		(oldest["root"] as Node3D).queue_free()
	var root := Node3D.new()
	root.position = pos
	add_child(root)
	var mats: Array = []
	var bases: Array = []
	for i in range(SMOKE_PUFFS):
		# golden-angle spiral in the horizontal plane, gently rising — fills the disc evenly
		var t := float(i) / float(SMOKE_PUFFS)
		var ang := float(i) * 2.39996323   # golden angle (rad)
		var rr := radius * 0.92 * sqrt(t)
		# billow up from near the ground (low puffs wide, higher puffs pulled toward the centre)
		var off := Vector3(cos(ang) * rr, radius * (0.05 + 0.45 * t), sin(ang) * rr)
		var size := radius * (1.25 - 0.5 * t)    # bigger near the base, smaller up top
		var node := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = size * 0.5; sm.height = size; sm.radial_segments = 7; sm.rings = 4
		node.mesh = sm
		node.position = off
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(SMOKE_COLOR.r, SMOKE_COLOR.g, SMOKE_COLOR.b, 0.0)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(node)
		mats.append(mat)
		bases.append(node.position)
	_smokes.append({"root": root, "mats": mats, "born": now, "dur": duration, "base": bases})


func _age_smokes(now: float) -> void:
	if _smokes.is_empty():
		return
	var live: Array = []
	for s: Dictionary in _smokes:
		var age: float = now - float(s["born"])
		var dur: float = float(s["dur"])
		if age >= dur:
			(s["root"] as Node3D).queue_free()
			continue
		var env := SmokeCloud.envelope(age, dur)
		var a := env * SMOKE_BASE_ALPHA
		var mats: Array = s["mats"]
		for mat: StandardMaterial3D in mats:
			var c := mat.albedo_color; c.a = a; mat.albedo_color = c
		# slow drift upward + slight spread as it ages, so the cloud breathes instead of sitting static
		var grow := 1.0 + clampf(age / dur, 0.0, 1.0) * 0.25
		var root := s["root"] as Node3D
		root.scale = Vector3(grow, grow, grow)
		live.append(s)
	_smokes = live


## Visual QA (--smoke-test): once the camera exists, pop one smoke cloud a few metres ahead so a
## screenshot reliably catches a billowed cloud (no bot/throw needed).
func _ensure_smoke_demo(now: float) -> void:
	if not smoke_demo or _camera == null or now < _smoke_demo_next:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	# Re-pop every 4 s (cloud lives 5 s) so a fresh cloud lands in front of the camera AFTER the
	# player has deployed away from the origin — a one-shot would fire at the pre-deploy origin.
	_smoke_demo_next = now + 4.0
	var fwd := (-cb.basis.z).normalized()
	var at := cb.origin + fwd * 16.0   # downrange, so it reads as a discrete cloud (not enveloping the eye)
	at.y = 0.0
	spawn_smoke(at, 6.0, 5.0, now)


## Visual QA (--grenade-test): lob a cosmetic grenade across the view every ~0.5 s (alternating
## frag/smoke) so a screenshot reliably catches one mid-arc.
func _ensure_grenade_demo(now: float) -> void:
	if not grenade_demo or _camera == null or now < _grenade_demo_next:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	_grenade_demo_next = now + 0.5
	var fwd := (-cb.basis.z).normalized()
	var dir := (fwd + Vector3.UP * 0.5).normalized()   # forward + up, so it arcs across the frame
	var kind := Grenade.FRAG if _grenade_demo_i % 2 == 0 else Grenade.SMOKE
	_grenade_demo_i += 1
	throw_grenade(cb.origin + fwd * 0.6, Grenade.launch_velocity(dir), kind, now)


# =============================================================================
#  Deployed gadgets (M7) — driven by the server's authoritative GADGET_LIST.
# =============================================================================

## Replace the rendered gadget set with `list` (each {kind, pos, face}). Cheap full rebuild — the
## server only resends when the set changes, and gadgets are few. C4 sticks a charge with a blinking
## light; a mine is a small directional claymore; a bag is a supply crate.
func set_gadgets(list: Array) -> void:
	for n in _gadget_nodes:
		(n as Node3D).queue_free()
	_gadget_nodes.clear()
	for g: Dictionary in list:
		var pos: Vector3 = g["pos"]
		if not pos.is_finite():
			continue
		var node := _make_gadget(int(g["kind"]), g.get("face", Vector3.ZERO))
		node.position = pos
		add_child(node)
		_gadget_nodes.append(node)


func _make_gadget(kind: int, face: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Gadget"
	match kind:
		GadgetList.MINE:   # claymore: a small slab on stub legs, fronted by the kill direction
			root.name = "Mine"
			var slab := MeshInstance3D.new()
			var smesh := BoxMesh.new(); smesh.size = Vector3(0.34, 0.16, 0.08)
			slab.mesh = smesh; slab.position = Vector3(0, 0.14, 0)
			var mmat := StandardMaterial3D.new(); mmat.albedo_color = Color(0.22, 0.26, 0.18); mmat.roughness = 0.8
			slab.material_override = mmat; slab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(slab)
			if face.length() > 0.01:
				# Orient via Basis (look_at needs the node in the tree; this runs before add_child).
				root.transform.basis = Basis.looking_at(Vector3(face.x, 0.0, face.z), Vector3.UP)
		GadgetList.BAG:    # supply crate
			root.name = "Bag"
			var crate := MeshInstance3D.new()
			var cmesh := BoxMesh.new(); cmesh.size = Vector3(0.55, 0.4, 0.4)
			crate.mesh = cmesh; crate.position = Vector3(0, 0.2, 0)
			var bmat := StandardMaterial3D.new(); bmat.albedo_color = Color(0.36, 0.42, 0.22); bmat.roughness = 0.9
			crate.material_override = bmat; crate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(crate)
		_:                 # C4: a dark brick of charge with a small red indicator light
			root.name = "C4"
			var brick := MeshInstance3D.new()
			var bkmesh := BoxMesh.new(); bkmesh.size = Vector3(0.26, 0.12, 0.16)
			brick.mesh = bkmesh; brick.position = Vector3(0, 0.06, 0)
			var c4mat := StandardMaterial3D.new(); c4mat.albedo_color = Color(0.30, 0.22, 0.14); c4mat.roughness = 0.85
			brick.material_override = c4mat; brick.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(brick)
			var led := MeshInstance3D.new()
			var lmesh := BoxMesh.new(); lmesh.size = Vector3(0.05, 0.05, 0.05)
			led.mesh = lmesh; led.position = Vector3(0.08, 0.14, 0)
			var lmat := StandardMaterial3D.new()
			lmat.albedo_color = Color(1.0, 0.1, 0.1); lmat.emission_enabled = true
			lmat.emission = Color(1.0, 0.1, 0.1); lmat.emission_energy_multiplier = 2.0
			led.material_override = lmat; led.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(led)
	return root


## Visual QA (--revive-marker-test): lay a downed friendly soldier in front of the camera with the
## bobbing red revive marker above it (mirrors the live downed-friendly branch: REVIVE colour + bob).
func _ensure_revive_demo(now: float) -> void:
	if not revive_demo or _camera == null:
		return
	if _revive_demo_marker == null:
		var dummy := CharacterKit.build()
		dummy.position = Vector3(0.0, -1.5, -5.0)   # camera-local: in front, on the ground
		dummy.rotation = Vector3(-PI * 0.5, 0.0, 0.0)   # tip onto its back (downed = face-up)
		_camera.add_child(dummy)
		_revive_demo_marker = _make_friend_marker()
		(_revive_demo_marker.material_override as StandardMaterial3D).albedo_color = REVIVE_MARKER_COLOR
		_camera.add_child(_revive_demo_marker)
	_revive_demo_marker.position = Vector3(0.0, -0.4 + RevivePulse.bob(now), -5.0)   # bob above the body


## Visual QA (--gadget-test): once deployed, keep a C4 / mine / bag laid out in front of the camera
## (re-placed each second relative to the eye, so they appear after the player spawns away from origin).
func _ensure_gadget_demo(now: float) -> void:
	if not gadget_demo or _camera == null or now < _gadget_demo_next:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	_gadget_demo_next = now + 1.0
	var fwd := (-cb.basis.z).normalized()
	var right := cb.basis.x.normalized()
	var base := cb.origin + fwd * 4.0; base.y = 0.0
	set_gadgets([
		{"kind": GadgetList.C4, "pos": base - right * 1.4, "face": Vector3.ZERO},
		{"kind": GadgetList.MINE, "pos": base, "face": -fwd},
		{"kind": GadgetList.BAG, "pos": base + right * 1.4, "face": Vector3.ZERO},
	])


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


const IMPACT_WALL_COLOR := Color(0.62, 0.60, 0.56, 0.7)    # grey wall dust
const IMPACT_DIRT_COLOR := Color(0.45, 0.36, 0.24, 0.75)   # brown dirt
const IMPACT_FLESH_COLOR := Color(0.55, 0.06, 0.06, 0.8)   # red blood mist

## Cosmetic bullet impact: a small kind-coloured puff + a few specks kicked off the surface.
## kind: Protocol.IMPACT_WALL (0) = grey wall dust, IMPACT_DIRT (1) = brown dirt,
## IMPACT_FLESH (2) = a smaller red blood mist with just a couple of droplets.
func spawn_impact(pos: Vector3, kind: int, now: float) -> void:
	if not pos.is_finite():
		return
	var col: Color
	var size: float
	var chips: int
	match kind:
		1:  # IMPACT_DIRT
			col = IMPACT_DIRT_COLOR; size = 0.6; chips = 4
		2:  # IMPACT_FLESH — a small blood mist, a couple of light droplets (no hard chips)
			col = IMPACT_FLESH_COLOR; size = 0.45; chips = 2
		_:  # IMPACT_WALL
			col = IMPACT_WALL_COLOR; size = 0.6; chips = 4
	_spawn_puff(pos, size, 0.4, now, col)
	_spawn_impact_chips(pos, now, col, chips)
	impact.emit(pos, kind)   # client_main routes this to a spatial thud (wall/dirt; flesh stays silent)

## A few small specks flung off an impact point (smaller/fewer/slower than explosion debris). Reuses
## the _debris pool so _age_debris integrates + settles them.
func _spawn_impact_chips(pos: Vector3, now: float, color: Color, count := 4) -> void:
	if count <= 0:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in range(count):
		var node := MeshInstance3D.new()
		var bmesh := BoxMesh.new(); bmesh.size = Vector3(0.06, 0.06, 0.06)
		node.mesh = bmesh; node.position = pos; node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		var ang := TAU * float(i) / float(count)
		var vel := Vector3(cos(ang) * 2.2, 2.6 + float(i % 2) * 1.0, sin(ang) * 2.2)
		_debris.append({"node": node, "vel": vel, "die": now + DEBRIS_TTL * 0.5})


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


const CASING_TTL := 3.0
const CASING_GRAVITY := 16.0
const CASING_MAX := 40             # cap live casings (drop oldest) so sustained auto-fire stays bounded

func _casing_material() -> StandardMaterial3D:
	if _casing_mat == null:
		_casing_mat = StandardMaterial3D.new()
		_casing_mat.albedo_color = Color(0.75, 0.56, 0.22)   # brass
		_casing_mat.metallic = 0.8
		_casing_mat.roughness = 0.35
	return _casing_mat

## Eject a brass shell casing from the local gun's port on each shot. Spawned in WORLD space at the
## camera (so it tumbles + falls independently of the view, not glued to it), flung to the right of
## the eye with a touch of up/back + per-shot variation. Cosmetic, local-player only. View-only (§7).
func eject_casing(now: float) -> void:
	if _camera == null:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	var right := cb.basis.x.normalized()
	var up := cb.basis.y.normalized()
	var fwd := (-cb.basis.z).normalized()
	_casing_i += 1
	var jitter := float((_casing_i % 5) - 2) * 0.4   # -0.8..0.8 spread, no per-frame RNG
	var node := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.014; cyl.bottom_radius = 0.014; cyl.height = 0.07
	node.mesh = cyl
	node.material_override = _casing_material()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = cb.origin + right * 0.22 + up * (-0.10) + fwd * 0.42   # near the ejection port
	node.rotation = Vector3(0.0, 0.0, PI * 0.5)   # lay it on its side initially
	add_child(node)
	# Pop up-and-right so the brass is briefly visible near the gun before it falls away to the right
	# (a pure rightward eject leaves the frame almost instantly).
	var vel := right * (1.4 + jitter) + up * 2.8 + fwd * (-0.3)
	var spin := Vector3(8.0 + jitter, 5.0, 11.0)   # rad/s tumble
	_casings.append({"node": node, "vel": vel, "spin": spin, "die": now + CASING_TTL})
	while _casings.size() > CASING_MAX:
		var old: Dictionary = _casings.pop_front()
		(old["node"] as Node3D).queue_free()

## Visual QA (--casing-test): eject a casing every ~0.12 s so a screenshot catches brass mid-air.
func _ensure_casing_demo(now: float) -> void:
	if not casing_demo or _camera == null or now < _casing_demo_next:
		return
	_casing_demo_next = now + 0.12
	eject_casing(now)

func _age_casings(now: float, delta: float) -> void:
	if _casings.is_empty():
		return
	var dt := clampf(delta, 0.0, 0.1)
	var live: Array = []
	for c: Dictionary in _casings:
		if now >= float(c["die"]):
			(c["node"] as Node3D).queue_free()
			continue
		var node: Node3D = c["node"]
		var vel: Vector3 = c["vel"]
		vel.y -= CASING_GRAVITY * dt
		var npos := node.position + vel * dt
		if npos.y <= 0.02:
			npos.y = 0.02
			vel = Vector3(vel.x * 0.3, absf(vel.y) * 0.25, vel.z * 0.3)   # small bounce + friction
			c["spin"] = (c["spin"] as Vector3) * 0.4
		node.position = npos
		node.rotation += (c["spin"] as Vector3) * dt
		c["vel"] = vel
		live.append(c)
	_casings = live


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


## Visual QA (--impact-test): pump bullet impacts in front of the camera so a screenshot catches
## the dust puffs + chips. Alternates wall/dirt kinds across a small spread.
func _ensure_impact_demo(now: float) -> void:
	if not impact_demo or _camera == null or now < _impact_next:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	_impact_next = now + 0.18
	var fwd := (-cb.basis.z).normalized()
	for j in range(3):
		_impact_i += 1
		var lateral := cb.basis.x * (float((_impact_i % 5) - 2) * 0.9)
		var rise := cb.basis.y * (float((_impact_i % 3) - 1) * 0.7)
		spawn_impact(cb.origin + fwd * 6.0 + lateral + rise, _impact_i % 3, now)   # cycle wall/dirt/flesh


## Visual QA (--footstep-test): pump footstep dust scuffs along the ground in front of the view so a
## screenshot reliably catches the kicked-up dust (no need for a bot to run past at the right moment).
## Same puff as a real footfall; only the placement is camera-relative + on a steady cadence.
func _ensure_footstep_demo(now: float) -> void:
	if not footstep_demo or _camera == null or now < _footstep_next:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	_footstep_next = now + 0.22
	var fwd := (-cb.basis.z).normalized()
	for j in range(3):
		# a little trail of footfalls receding ahead + to the side, at roughly ground level
		var lateral := cb.basis.x * (float(j - 1) * 0.8)
		var at := cb.origin + fwd * (4.0 + float(j) * 1.2) + lateral
		at.y -= 1.5   # drop toward the feet/ground from the eye height
		_spawn_footstep_fx(at, 0.4 + 0.2 * float(j), now)


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
		_tick_footstep(int(id), es, now)
		if local_team >= 0 and es.team == local_team:
			var marker: MeshInstance3D = _acquire_marker(int(id))
			# A downed teammate keeps the marker but re-tints to the revive colour and bobs, so you can
			# pick out who needs picking up; an alive teammate is the steady blue friendly marker.
			var mk_mat := marker.material_override as StandardMaterial3D
			if es.is_downed:
				mk_mat.albedo_color = REVIVE_MARKER_COLOR
				marker.position = Vector3(es.pos.x, es.pos.y + FRIEND_MARKER_Y + RevivePulse.bob(now), es.pos.z)
			else:
				mk_mat.albedo_color = ArtPalette.FRIENDLY
				marker.position = Vector3(es.pos.x, es.pos.y + FRIEND_MARKER_Y, es.pos.z)
		else:
			_release_marker(int(id))


## Remote-pawn footstep: accumulate ground travel between authoritative position updates and, on a
## full stride, kick a dust puff at the feet + emit a spatial footstep. The interpolated position only
## advances at the sim rate, so process only frames where it actually moved (distance-based cadence,
## not time-based) — an idle pawn keeps its leftover accumulator instead of draining it every frame.
func _tick_footstep(id: int, es: EntityState, now: float) -> void:
	var prev: Vector3 = _step_prev.get(id, es.pos)
	var flat := Vector3(es.pos.x - prev.x, 0.0, es.pos.z - prev.z)
	var dist := flat.length()
	if dist <= 0.0001:
		return   # no authoritative movement this frame (inter-tick or stationary) — hold the accumulator
	var speed := dist / SimLoop.DT   # interpolated pos steps at the sim rate; DT is the real interval
	var grounded := not es.climbing and absf(es.pos.y - prev.y) < 0.3   # falling/climbing -> no steps
	var r := FootstepCadence.advance(_step_accum.get(id, 0.0), dist, speed, es.stance, grounded)
	_step_accum[id] = r["accum"]
	_step_prev[id] = es.pos
	if r["fired"]:
		_spawn_footstep_fx(es.pos, r["intensity"], now)


## Estimate a remote's airborne state from its interpolated vertical motion (no `grounded` on the wire)
## and kick a dust burst when it lands from a fall. Called every frame per remote so the vy estimate is
## continuous (even across pose branches). Returns true while airborne (drives the jump/fall pose).
func _update_airborne(id: int, es: EntityState, dt: float, now: float) -> bool:
	var py: float = _air_y.get(id, es.pos.y)
	var d := clampf(dt, 0.001, 0.1)
	var inst := (es.pos.y - py) / d
	var vy: float = lerpf(_air_vy.get(id, 0.0), inst, 0.35)   # smooth the interpolation-stepped delta
	_air_y[id] = es.pos.y
	_air_vy[id] = vy
	if vy < -AIR_FALL_VY:
		_air_fell[id] = true
	if bool(_air_fell.get(id, false)) and absf(vy) < AIR_LAND_VY:
		_air_fell[id] = false
		_spawn_footstep_fx(es.pos, 1.0, now)   # strong dust burst at the feet on touchdown
	return absf(vy) > AIR_JUMP_VY and not es.climbing

## Kick the local viewmodel down on a hard landing (client_main calls this off the predicted pawn's
## airborne->grounded transition). Decays back in _update_viewmodel_locomotion. View-only.
func play_land_dip(strength: float) -> void:
	_vm_land_dip = maxf(_vm_land_dip, clampf(strength, 0.0, 1.0) * MAX_LAND_DIP)


## Local-pawn footstep: the predicted pawn carries real velocity/grounded each render frame, so drive
## the cadence time-based (dist = speed * dt). Audio only (no dust — the local feet are below the eye);
## emitted at the eye so it plays centred (the listener sits there).
func _tick_local_footstep(pawn: Pawn, dt: float, eye: Vector3, now: float) -> void:
	if pawn == null or dt <= 0.0:
		return
	var vel: Vector3 = pawn.velocity
	var speed := Vector2(vel.x, vel.z).length()
	var r := FootstepCadence.advance(_local_step_accum, speed * dt, speed, pawn.stance, pawn.grounded)
	_local_step_accum = r["accum"]
	if r["fired"] and eye.is_finite():
		footstep.emit(eye, r["intensity"])


## Kick a dust scuff at a footfall and emit a spatial footstep sound. Dust scales a touch with speed.
func _spawn_footstep_fx(pos: Vector3, intensity: float, now: float) -> void:
	if not pos.is_finite():
		return
	var at := Vector3(pos.x, pos.y + 0.05, pos.z)   # at the feet, just clear of the ground
	_spawn_puff(at, lerpf(0.22, 0.42, intensity), FOOTSTEP_PUFF_TTL, now, FOOTSTEP_DUST_COLOR)
	footstep.emit(at, intensity)


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
## Visual QA (--climb-test): pin an upright dummy next to a climbing-posed one so a screenshot shows
## the ladder lean vs. standing. Camera-parented (fixed framing); not snapshot-driven.
func _ensure_climb_demo(now: float) -> void:
	if not climb_demo or _climb_demo_done or _camera == null or now < 1.0:
		return
	_climb_demo_done = true
	var upright := CharacterKit.build()
	upright.position = Vector3(-0.8, -1.1, -3.0)
	_camera.add_child(upright)
	var climber := CharacterKit.build()
	# Same forward lean the real climbing pose applies (about the feet), for the A/B framing.
	climber.transform.basis = Basis.IDENTITY.rotated(Vector3(1, 0, 0), CLIMB_PITCH)
	climber.position = Vector3(0.8, -1.1, -3.0)
	_camera.add_child(climber)


## Visual QA (--jump-test): upright dummy next to an airborne-posed (tuck + lean) one.
func _ensure_jump_demo(now: float) -> void:
	if not jump_demo or _jump_demo_done or _camera == null or now < 1.0:
		return
	_jump_demo_done = true
	var upright := CharacterKit.build()
	upright.position = Vector3(-0.8, -1.1, -3.0)
	_camera.add_child(upright)
	var jumper := CharacterKit.build()
	jumper.transform.basis = Basis.IDENTITY.rotated(Vector3(1, 0, 0), JUMP_PITCH)
	jumper.scale = Vector3(1.0, JUMP_TUCK, 1.0)   # same tuck the airborne pose applies
	jumper.position = Vector3(0.8, -0.7, -3.0)    # lifted a touch to read as off the ground
	_camera.add_child(jumper)


## Visual QA (--land-test): pump a landing dust burst in front of the camera + kick the viewmodel dip
## on a cadence, so a screenshot catches the touchdown FX.
func _ensure_land_demo(now: float) -> void:
	if not land_demo or _camera == null or now < _land_demo_next:
		return
	_land_demo_next = now + 0.9
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	var fwd := (-cb.basis.z).normalized()
	var at := cb.origin + fwd * 3.5; at.y = 0.05
	_spawn_footstep_fx(at, 1.0, now)
	play_land_dip(1.0)


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
	_step_accum.erase(id)
	_step_prev.erase(id)
	_air_y.erase(id)
	_air_vy.erase(id)
	_air_fell.erase(id)
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
	# Airborne inference must run every frame (continuous vy estimate) — before the early-return poses.
	var airborne := _update_airborne(id, es, render_delta, _now)
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

	if es.climbing:
		# On a ladder: lean the figure forward toward the rungs so it doesn't read as standing/floating
		# upright while it slides up. Pitch about the feet (node origin), keeping the stance height scale.
		var cb := Basis.IDENTITY.rotated(Vector3.UP, es.yaw)
		cb = cb.rotated(cb.x, CLIMB_PITCH)   # +X pitch = lean forward (same sign convention as prone)
		node.position = Vector3(es.pos.x, es.pos.y, es.pos.z)
		node.transform.basis = cb
		node.scale = Vector3(1.0, height / CharacterKit.STAND_HEIGHT, 1.0)
		return

	if airborne:
		# Jumping/falling: a slight forward tuck + mild vertical compress so an off-the-ground figure
		# reads as airborne rather than gliding bolt-upright (remotes carry no jump state on the wire).
		var jb := Basis.IDENTITY.rotated(Vector3.UP, es.yaw)
		jb = jb.rotated(jb.x, JUMP_PITCH)
		node.position = Vector3(es.pos.x, es.pos.y, es.pos.z)
		node.transform.basis = jb
		node.scale = Vector3(1.0, (height / CharacterKit.STAND_HEIGHT) * JUMP_TUCK, 1.0)
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
	_rebuild_structure_batches(world_view.structures())


## Batched structure render (perf): all pieces sharing a visual key (piece_id + damage bucket + skirt)
## are IDENTICAL geometry, so they draw as one MultiMesh instead of one node per piece. Collapses the
## town's ~8k pieces / ~16k draw calls to a few hundred. Rebuilt only on a structure-version change
## (build/destroy/damage/collapse) — static the rest of the time. Per-piece build/destroy pops are
## dropped (cosmetic); destruction still reflects instantly on the next rebuild.
func _rebuild_structure_batches(structs: Dictionary) -> void:
	for n: Node3D in _struct_batches:
		n.queue_free()
	_struct_batches.clear()
	# Drop any legacy per-piece nodes from the old path (first rebuild after connect).
	for id_v: Variant in _struct_active:
		(_struct_active[id_v] as Node3D).queue_free()
	_struct_active.clear()
	_struct_key_of.clear()
	_building_centroid.clear()

	# Group piece world-transforms by visual key; track a per-building centroid for collapse rubble.
	var groups: Dictionary = {}   # key -> {sample: rec, xforms: Array[Transform3D]}
	for id_v: Variant in structs:
		var rec: Dictionary = structs[id_v]
		var key: String = _struct_visual_key(rec)
		if not groups.has(key):
			groups[key] = {"sample": rec, "xforms": []}
		var xf := _structure_xform(rec)
		(groups[key]["xforms"] as Array).append(xf)
		var bid: int = int(rec.get("building_id", 0))
		if bid != 0:
			_building_centroid[bid] = xf.origin   # last piece's position is fine for a placeholder marker

	# One MultiMeshInstance3D per (visual key, mesh slot of the piece's kit node).
	for key: String in groups:
		var g: Dictionary = groups[key]
		var template: Node3D = _make_structure_node(g["sample"])
		var slots: Array = []
		_collect_mesh_slots(template, Transform3D.IDENTITY, slots)
		template.queue_free()   # template was never added to the tree
		var xforms: Array = g["xforms"]
		for slot: Dictionary in slots:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = slot["mesh"]
			mm.instance_count = xforms.size()
			for i in xforms.size():
				mm.set_instance_transform(i, (xforms[i] as Transform3D) * (slot["local"] as Transform3D))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = slot["material"]
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			add_child(mmi)
			_struct_batches.append(mmi)


## Visual key: pieces with the same id + damage bucket + skirt are byte-identical geometry, so they
## share a MultiMesh. (Skirt depends on cell.y==0, so two same-type pieces at different floors differ.)
func _struct_visual_key(rec: Dictionary) -> String:
	var type_idx: int = int(rec.get("type", 0))
	var cell: Vector3i = rec["cell"] as Vector3i
	var piece_id: String = STRUCT_TYPE_ID[type_idx] if type_idx < STRUCT_TYPE_ID.size() else "wall"
	var skirt: bool = cell.y == 0 and (piece_id.begins_with("bwall") or piece_id == "bcolumn" \
		or piece_id.begins_with("prop_"))
	return "%d:%d:%d" % [type_idx, _bucket_of(rec), 1 if skirt else 0]


## World transform of a piece (mirrors _pose_structure: cell-centred + lifted, Y-yawed).
func _structure_xform(rec: Dictionary) -> Transform3D:
	var cell: Vector3i = rec["cell"] as Vector3i
	var half := BuildGrid.CELL_SIZE * 0.5
	var pos := Vector3(float(cell.x) * BuildGrid.CELL_SIZE + half,
		float(cell.y) * BuildGrid.CELL_SIZE + STRUCT_LIFT,
		float(cell.z) * BuildGrid.CELL_SIZE + half)
	var basis := Basis.from_euler(Vector3(0.0, BuildGrid.yaw_radians(int(rec.get("yaw", 0))), 0.0))
	return Transform3D(basis, pos)


## Walk a kit node, collecting each MeshInstance3D as {mesh, material, local} (transform relative to
## the kit root) so each can become a MultiMesh slot.
func _collect_mesh_slots(node: Node3D, parent_xform: Transform3D, slots: Array) -> void:
	var here := parent_xform * node.transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			slots.append({"mesh": mi.mesh, "material": mi.material_override, "local": here})
	for child in node.get_children():
		if child is Node3D:
			_collect_mesh_slots(child as Node3D, here, slots)


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
	# Sprint FOV kick — widen the view a touch while sprinting (eased via _vm_sprint_t) for a
	# sense of speed. Composes with the sprint-lower viewmodel; settles back when not sprinting.
	_camera.fov = fov + _vm_sprint_t * SPRINT_FOV_ADD


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
		if vid == _WRECK_DEMO_VID or vid == _DMG_DEMO_VID:
			continue   # the --vehicle-test demo vehicles are camera-placed, never in the snapshot
		if not vehicles.has(vid):
			to_release.append(vid)
	for vid: int in to_release:
		var node: Node3D = _vehicle_active[vid] as Node3D
		_set_vehicle_wrecked(node, false)   # restore intact look before pooling (recycled nodes start fresh)
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
		# Wreck state is self-correcting off the replicated HP: destroyed (hp<=0) reads as a burnt,
		# tilted hulk; a respawn restores hp>0 and the intact look. Robust for vehicles that come
		# into view already destroyed or respawn out of sight — no event needed for the persistent look.
		_set_vehicle_wrecked(node, vs.hp <= 0)
		var maxhp: int = _veh_max_hp(vs.type)
		var ratio: float = (float(vs.hp) / float(maxhp)) if maxhp > 0 else 1.0
		_ensure_vehicle_smoke(node, ratio, _now)


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


const WRECK_CHAR_COLOR := Color(0.10, 0.09, 0.08)   # blackened, burnt-out hulk
const WRECK_TILT := 0.14                             # rad (~8°) lean of a settled wreck
const WRECK_SMOKE_PERIOD := 0.7                      # s between wreck smoke puffs (per visible wreck)
const DAMAGE_SMOKE_RATIO := 0.5                      # start smoking once hp drops below this fraction of max
var _veh_catalog: VehicleCatalog = null             # lazy data/vehicles.json -> per-type max_hp for damage %

## max_hp for a vehicle type (data/vehicles.json), 0 if unknown. Lazy-loads the catalog once so the
## damage-smoke threshold is a fraction of the real max rather than a magic absolute. View-only.
func _veh_max_hp(type: int) -> int:
	if _veh_catalog == null:
		_veh_catalog = VehicleCatalog.load_file("res://data/vehicles.json")
	if _veh_catalog == null:
		return 0
	var def := _veh_catalog.def_of(type)
	return int(def.get("max_hp", 0))

func _wreck_material() -> StandardMaterial3D:
	if _wreck_mat == null:
		_wreck_mat = StandardMaterial3D.new()
		_wreck_mat.albedo_color = WRECK_CHAR_COLOR
		_wreck_mat.roughness = 1.0
		_wreck_mat.metallic = 0.0
	return _wreck_mat

## Toggle a vehicle node between its intact and burnt-wreck look. Idempotent (guarded by a node
## meta flag) so it's safe to call every frame from the pool sync. Wrecking chars every body mesh
## and leans the hulk; un-wrecking restores the original materials + upright pose (recycled/respawned
## nodes come back clean). View-only (AGENTS.md §7).
func _set_vehicle_wrecked(node: Node3D, wrecked: bool) -> void:
	if node == null or bool(node.get_meta("wrecked", false)) == wrecked:
		return
	node.set_meta("wrecked", wrecked)
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if wrecked:
				if not mi.has_meta("orig_mat"):
					mi.set_meta("orig_mat", mi.material_override)
				mi.material_override = _wreck_material()
			elif mi.has_meta("orig_mat"):
				mi.material_override = mi.get_meta("orig_mat")
	if wrecked:
		node.rotation.z = WRECK_TILT
	else:
		node.rotation.x = 0.0
		node.rotation.z = 0.0

## One-shot vehicle-destruction VFX: a big fireball + smoke + scattered debris at pos. Driven by the
## reliable VEHICLE_DESTROYED event (cosmetic), the same way DETONATION drives spawn_explosion. The
## persistent burnt hulk is NOT set here — it's driven purely by the replicated hp<=0 in the pool
## sync, which avoids a flicker: the event can beat the hp=0 snapshot by a stagger/interest window,
## so an immediate event-wreck would be un-wrecked by the next frame's still-stale (hp>0) snapshot.
## The hp=0 snapshot lands within a frame or two — under the fireball's lifetime, which covers the
## gap. (vid accepted for symmetry with the wire/audio call site.) View-only (AGENTS.md §7).
func destroy_vehicle(_vid: int, pos: Vector3, now: float) -> void:
	if not pos.is_finite():
		return
	_spawn_blast(pos + Vector3(0, 1.2, 0), Color(1.0, 0.6, 0.16), 1.6, 7.0, BLAST_TTL * 1.6, now)
	_spawn_puff(pos + Vector3(0, 1.4, 0), 4.0, 1.2, now, Color(0.18, 0.17, 0.16, 0.7))
	_spawn_debris(pos + Vector3(0, 0.8, 0), now)

## Smouldering column off a hurt or destroyed vehicle — a puff on a throttle held in node meta
## (cheap: one small puff per period per on-screen vehicle). `ratio` = hp/max_hp:
##   <=0  → wrecked: a slow, heavy, near-black column.
##   <DAMAGE_SMOKE_RATIO → damaged: a lighter grey wisp that thickens and quickens toward death.
##   else → healthy: nothing.
## Called from the pool sync for every visible vehicle. View-only (AGENTS.md §7).
func _ensure_vehicle_smoke(node: Node3D, ratio: float, now: float) -> void:
	var period: float
	var color: Color
	var size: float
	if ratio <= 0.0:
		period = WRECK_SMOKE_PERIOD
		color = Color(0.16, 0.15, 0.14, 0.6)
		size = 1.8
	elif ratio < DAMAGE_SMOKE_RATIO:
		var sev: float = clampf(1.0 - ratio / DAMAGE_SMOKE_RATIO, 0.0, 1.0)   # 0 at threshold → 1 near death
		period = lerpf(1.4, 0.5, sev)
		color = Color(0.34, 0.33, 0.32, lerpf(0.28, 0.5, sev))
		size = lerpf(0.9, 1.5, sev)
	else:
		return
	if now < float(node.get_meta("veh_smoke_next", 0.0)):
		return
	node.set_meta("veh_smoke_next", now + period)
	_spawn_puff(node.position + Vector3(0, 1.6, 0), size, 1.6, now, color)


func _ensure_wreck_demo(now: float) -> void:
	# --vehicle-test: a destroyed transport (burnt hulk + blast) plus a heavily-damaged one (grey
	# smoke wisp) in front of the camera, for the screenshot. One-shot creation; smoke keeps pumping
	# (the demo nodes aren't snapshot-driven, so they're driven through _ensure_vehicle_smoke directly).
	if not wreck_demo or _camera == null or now < 1.0:
		return
	if not _wreck_demo_done:
		var cb := _camera.global_transform
		if not cb.origin.is_finite():
			return
		_wreck_demo_done = true
		var fwd := (-cb.basis.z).normalized()
		var right := cb.basis.x.normalized()
		var yaw := atan2(-fwd.x, -fwd.z)   # broadside-ish to the camera
		# Destroyed hulk, left of centre.
		var base := cb.origin + fwd * 9.0; base.y = 0.0
		var wreck := _make_vehicle_mesh()
		add_child(wreck)
		wreck.position = base - right * 3.0
		wreck.rotation.y = yaw
		_vehicle_active[_WRECK_DEMO_VID] = wreck
		destroy_vehicle(_WRECK_DEMO_VID, wreck.position + Vector3(0, 1.0, 0), now)
		_set_vehicle_wrecked(wreck, true)   # demo node isn't snapshot-driven, so mark the hulk directly
		# Heavily-damaged but alive transport, right of centre.
		var dmg := _make_vehicle_mesh()
		add_child(dmg)
		dmg.position = base + right * 3.0
		dmg.rotation.y = yaw
		_vehicle_active[_DMG_DEMO_VID] = dmg
	else:
		if _vehicle_active.has(_WRECK_DEMO_VID):
			_ensure_vehicle_smoke(_vehicle_active[_WRECK_DEMO_VID] as Node3D, 0.0, now)
		if _vehicle_active.has(_DMG_DEMO_VID):
			_ensure_vehicle_smoke(_vehicle_active[_DMG_DEMO_VID] as Node3D, 0.2, now)

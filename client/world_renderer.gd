class_name WorldRenderer
extends Node3D
## Presentation-only renderer. Reads MapDef + WorldView + Prediction each frame and draws the
## procedural low-poly art kit (client/art/*_kit.gd). Contains NO gameplay or authority logic
## (AGENTS.md §7, ADR-0005). Meshes come from the kits; swap kit internals without touching this.

const QaFlags := preload("res://client/qa_flags.gd")   # table-driven --*-test QA-flag registry (§D3)

# -- team colours (markers/beacons; kits own their own tints) ------------------
const TEAM_COLOR := [Color(0.2, 0.5, 1.0), Color(1.0, 0.3, 0.2)]  # [team0=blue, team1=red]
const NEUTRAL_COLOR := Color(0.6, 0.6, 0.6)

# -- structure type -> PieceCatalog id (array order == wire `type` int; see pieces/pieces.json) -----
# pieces.json order: 0 = sandbag, 1 = wall, 2+ = building pieces. Unknown/extra types fall back to "wall"
# (StructureKit also falls back to "wall" for any id it doesn't know).
const STRUCT_TYPE_ID := ["sandbag", "wall", "bwall", "bwall_window", "bwall_door", "bfloor", "bstair", "bcolumn", "brailing", "prop_crate", "bwall_half", "bwall_brick", "bwall_metal", "bwall_wood", "bwall_garage", "bwall_glass", "prop_table", "prop_chair", "prop_shelf", "prop_locker", "prop_barrel", "bwall_corner", "heavy_barricade", "fob", "brubble"]

# -- structure type -> chunk-grid (mirror of pieces/pieces.json `chunk_grid`) ----------
# Needed to turn a piece's live chunk alive-mask into a damage tier. Keep aligned with STRUCT_TYPE_ID
# order; unknown types fall back to the 8x8 fortification grid.
const STRUCT_TYPE_GRID := [8, 8, 8, 8, 8, 8, 8, 8, 4, 1, 8, 8, 8, 8, 8, 8, 1, 1, 1, 1, 1, 8, 8, 8, 1]

# -- structure feedback timing ------------------------------------------------
const STRUCT_LIFT := 0.06          # m: lift buildings onto a thin foundation (no grass z-fight)
const TERRAIN_CHUNK := 64          # M15: grid cells per terrain mesh chunk (free frustum culling, no LOD)

# -- viewmodel placeholder dimensions -----------------------------------------
const VM_OFFSET := Vector3(0.15, -0.12, -0.28)   # right / down / forward in camera space (pulled back from -0.40 — was too far forward)
const VM_ADS_OFFSET := Vector3(0.05, -0.20, -0.34)  # ADS: pull the gun inboard + low so it braces under the (zoomed) sightline without filling the view
const VM_YAW := PI   # GlbWeaponKit aims the barrel +Z; camera-forward is -Z, so flip 180° to aim with the view
var _ads_t := 0.0   # 0..1 aim-down-sights blend (client-only visual zoom/pose); set each frame by client_main
var _vm_photo_hidden := false   # viewmodel hidden by photo/free-fly mode
var _vm_scope_hidden := false   # viewmodel hidden while scoped (look through the scope, not at the gun)
var _vm_downed_hidden := false  # viewmodel hidden while downed (DBNO — you drop your weapon; C5)

# -- tracer (shot feedback) ---------------------------------------------------
const TRACER_POOL := 16
const TRACER_LEN := 80.0          # metres the beam extends along the aim
const TRACER_TTL := 0.06          # seconds the beam is visible (brief flash)
const TRACER_COLOR := Color(1.0, 0.85, 0.35)

# -- pool state ---------------------------------------------------------------
var _camera: Camera3D = null
var _tracers: Array = []          # [{node: MeshInstance3D, mat: StandardMaterial3D, die: float}]
var _tracer_idx: int = 0

# -- support links (heal/ammo/repair/revive beams + target aura) --------------
# Persistent node pool (one beam + one aura per slot) reused each frame from the server's
# SUPPORT_LIST. The beam spans giver->target chest; the aura pulses on the target. View-only.
const SUPPORT_POOL := 16
const SUPPORT_CHEST_Y := 1.2       # raise both endpoints to ~chest so the beam reads as person-to-person
const SUPPORT_REVIVE_KIND := 3     # matches Support/SUPPORT_COLORS REVIVE
const SUPPORT_COLORS := {
	0: Color(0.25, 1.0, 0.35),     # HEAL   — green
	1: Color(1.0, 0.78, 0.22),     # AMMO   — amber
	2: Color(0.35, 0.82, 1.0),     # REPAIR — cyan
	3: Color(0.65, 1.0, 0.78),     # REVIVE — white-green
}
var _support_links: Array = []     # raw [{giver, target, kind}] from the last SUPPORT_LIST
var _downed_urgency: Dictionary = {}   # id -> {frac: float 0..1, halted: bool} from the last DOWNED_LIST
var _support_slots: Array = []     # [{beam, beam_mat, aura, aura_mat}] persistent pool

# -- muzzle flash pool (MuzzleFlashKit; mirrors the tracer pool) ---------------
const FLASH_POOL := 16
var _flashes: Array = []          # [{node: MeshInstance3D, mat: StandardMaterial3D, die: float}]
var _flash_idx: int = 0

var _fx := FxPoolRef.new(self)    # rockets/thrown/puffs/blasts/debris — see client/fx_pool.gd
var _ladder_nodes: Dictionary = {}   # building_id -> [Node3D]; freed when the building collapses (H1)
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
var downed_urgency_demo := false  # --downed-urgency-test: a row of downed dummies at varying bleed urgency (QA)
var _downed_urgency_markers: Array = []
var boom_demo := false            # --boom-test: pump frag explosions in front of the camera (QA)
var _boom_next := 0.0
var _boom_i := 0
var wreck_demo := false           # --vehicle-test: blow up a transport in front of the camera (QA)
var _wreck_demo_done := false
var turret_demo := false          # --turret-test: an intact transport with its turret traversed off-axis (QA)
var _turret_demo_done := false
var heldweapon_demo := false      # --held-weapon-test: 5 side-on dummies, one per weapon silhouette (QA)
var _heldweapon_demo_done := false
var casing_demo := false          # --casing-test: pump shell casings from the gun port (QA)
var _casing_demo_next := 0.0
var impact_demo := false          # --impact-test: pump bullet impacts in front of the camera (QA)
var _impact_next := 0.0
var _impact_i := 0
# footstep feedback (view-only, AGENTS.md §7): a moving grounded pawn fires a footstep every stride
# of ground travel -> a small dust puff (remotes) + a spatial footstep sound (via the `footstep`
# signal, which client_main routes to the AudioDirector). Cadence math lives in FootstepCadence.
signal footstep(world_pos: Vector3, intensity: float, action: int)
signal impact(world_pos: Vector3, kind: int)   # a bullet terminated in the world (wall/dirt/flesh)

const FxPoolRef := preload("res://client/fx_pool.gd")   # transient one-shot FX pools (child node)


func _init() -> void:
	add_child(_fx)   # mount the transient-FX pool so its spawned nodes render with the scene
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
# --support-test QA: two dummy soldiers parented to the camera linked by a live support beam.
var support_demo := false
var _support_demo_done := false
var _support_demo_beam: MeshInstance3D = null
var _support_demo_beam_mat: StandardMaterial3D = null
var _support_demo_aura: MeshInstance3D = null
var _support_demo_aura_mat: StandardMaterial3D = null
# M12-P2 build-site ghosts: under-construction pieces render as a translucent silhouette of the
# target piece with an amber fill that rises from the ground in proportion to shovel progress.
# Set by client_main so the renderer can read each piece's build_cost (the wire only ships progress).
var piece_catalog: PieceCatalog = null
var _buildsite_nodes: Dictionary = {}   # struct id -> {root:Node3D, fill:MeshInstance3D, height, base_y, last_frac}
const BUILDSITE_FILL_COLOR := Color(0.95, 0.7, 0.2)     # amber "under construction" scaffold
# M12 build-placement preview ("hologram" of the piece about to be built).
const BUILD_OK_COLOR := Color(0.35, 1.0, 0.45)          # valid placement (green)
const BUILD_BAD_COLOR := Color(1.0, 0.35, 0.3)          # blocked placement (red)
var _build_preview: Node3D = null
var _build_preview_mat: StandardMaterial3D = null
var _build_preview_key := ""
# --buildsite-test QA: a camera-parented ghost FOB whose fill animates 0..1 for a screenshot.
var buildsite_demo := false
var _buildsite_demo_node_entry: Variant = null
var _buildsite_demo_done := false
const AIR_JUMP_VY := 2.2          # |vy| above this reads as airborne (jump/fall pose)
const AIR_FALL_VY := 3.5          # falling faster than this arms a landing dust burst
const AIR_LAND_VY := 1.0          # settle below this = grounded again
const JUMP_PITCH := 0.20          # rad forward lean of an airborne figure
const JUMP_TUCK := 0.88           # vertical scale of an airborne figure (mild tuck = off the ground)
const MAX_LAND_DIP := 0.09        # local viewmodel dip on a hard landing (m)
const LAND_DIP_DECAY := 8.0       # per-second ease of the land dip back to rest
# Remote fire-recoil: a brief body lean-back twitch on a remote pawn when it shoots (SHOT_FX).
var _fire_recoil: Dictionary = {} # id -> expire time of the fire-recoil twitch
const FIRE_RECOIL_TTL := 0.13     # s the body recoil twitch lasts
# Remote hit-flinch: a brief forward body jerk when a remote pawn's replicated health DROPS (took
# damage). health is in every snapshot, so this is pure client inference — no wire. Distinct from the
# backward fire-recoil (a flinch is a forward stagger); composes on top of it.
var _flinch: Dictionary = {}       # id -> expire time of the hit-flinch jerk
var _prev_health_r: Dictionary = {}   # id -> last-seen replicated health (to detect a drop)
const FLINCH_TTL := 0.16          # s the flinch jerk lasts
const FLINCH_PITCH := 0.16        # rad forward stagger at the moment of the hit
const FIRE_RECOIL_PITCH := 0.12   # rad peak backward lean on firing
# Remote reload: a remote pawn started reloading (RELOAD_FX). The procedural body tips forward over
# its weapon with a slow work-the-mag bob; the GLB path swaps to the "interact" clip.
var _reload_until: Dictionary = {} # id -> time the reload pose ends
const RELOAD_PITCH := 0.22        # rad forward lean (head down over the gun) while reloading
const RELOAD_BOB_HZ := 2.4        # work-the-mag bob frequency (Hz)
const RELOAD_BOB := 0.05          # rad bob amplitude added to the forward lean
# Remote melee: a remote pawn swung (MELEE_FX). A brief forward lunge that eases out — reads as a
# strike. The GLB path swaps to the authored "attack-melee" clip for the swing window.
var _melee_swing: Dictionary = {} # id -> expire time of the swing pose
const MELEE_SWING_TTL := 0.32     # s the swing/lunge pose lasts
const MELEE_SWING_PITCH := 0.34   # rad peak forward lunge on the swing
# Remote vault: a remote pawn auto-vaulted (VAULT_FX). A brief deep forward clamber over the obstacle
# (distinct from the upright airborne jump pose). Wins over the airborne inference for its window.
var _vault_until: Dictionary = {} # id -> expire time of the mantle pose
const VAULT_POSE_TTL := 0.5       # s the mantle pose lasts (~ a vault's duration)
const VAULT_PITCH := 0.6          # rad deep forward clamber lean (deeper than jump/climb)
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
var firepose_demo := false        # --firepose-test: pin a fire-recoil-posed dummy beside an upright one (QA)
var _firepose_demo_done := false
var flinch_demo := false          # --flinch-test: pin a hit-flinch-posed dummy beside an upright one (QA)
var _flinch_demo_done := false
var reloadpose_demo := false      # --remote-reload-test: pin a reload-posed dummy beside an upright one (QA)
var _reloadpose_demo_done := false
var meleepose_demo := false       # --remote-melee-test: pin a melee-lunge-posed dummy beside an upright one (QA)
var _meleepose_demo_done := false
var vaultpose_demo := false       # --remote-vault-test: pin a mantle-posed dummy beside an upright one (QA)
var _vaultpose_demo_done := false
var glbshoot_demo := false        # --glbshoot-test: GLB hold vs holding-both-shoot clip A/B (QA)
var _glbshoot_demo_done := false
# M11-P4 destruction cosmetics: per-piece debris/dust + a whole-building collapse cinematic + shake.
var destroy_demo := false         # --destroy-test: pump piece destruction bursts in front of camera (QA)
var _destroy_demo_next := 0.0
var collapse_demo := false        # --collapse-test: play a building collapse cinematic in front of camera (QA)
var _collapse_demo_next := 0.0
# Camera shake: a transient positional jitter (collapses + nearby blasts). Decays to rest.
var _shake_mag := 0.0             # current peak amplitude (m)
var _shake_until := 0.0          # time the active shake ends
var _shake_t0 := 0.0             # time the active shake began (for the decay envelope)

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
var _held_weapon: Dictionary = {}     # id(int) -> last-applied held-weapon id (re-shape GunMount on change)
var _seated_ids: Dictionary = {}      # id(int) -> {heading, seat}; vehicle occupants, posed seated (SeatPose)
var seat_pose_demo := false           # --seat-pose-test: pin a seated dummy beside an upright one (QA)
var _seat_pose_demo_done := false
var armor_demo := false               # --armor-demo: pin LIGHT/MEDIUM/HEAVY dummies in front of camera
var _armor_demo_done := false
var _entity_ap: Dictionary = {}       # id(int) -> AnimationPlayer (only when use_models)

# Batched structure render: visual key -> {ids: {piece_id: true}, mmis: Array[MultiMeshInstance3D]}.
# Persistent group state so a structure delta rebuilds ONLY the affected key's MultiMeshes —
# a full regroup of ~8k pieces per delta was the render-side twin of the M11 encode cliff.
var _struct_groups: Dictionary = {}
# id(int) -> "type:bucket" key; a change means rebuild (kit geometry/tint is baked at build)
var _struct_key_of: Dictionary = {}
# M11 Gate-B hole-aware geometry: shared unit-cube mesh + per-type material for PROMOTED (partially
# carved) pieces rendered as a per-chunk hole grid. Cached so a carve delta doesn't re-alloc.
var _promoted_cube: BoxMesh = null
var _promoted_mats: Dictionary = {}
# last WorldView.structs_version() we synced; the per-frame pool walk is skipped while unchanged
# (structures are static, so re-acquiring/re-posing ~thousands of pieces every frame was the
# dominant client cost on dense maps — 35 ms/frame on conquest_town's 77 buildings).
var _struct_synced_ver: int = -1
# friend markers: id(int) -> MeshInstance3D (blue triangle above teammates; BattleBit-style)
var _friend_markers: Dictionary = {}
var _marker_free_list: Array = []
const FRIEND_MARKER_Y := 2.35    # world height above the pawn's feet (fixed; ignores stance squash)
const REVIVE_MARKER_COLOR := Color(1.0, 0.32, 0.22)   # downed teammate (needs revive) — stands out from blue
# Bleed-out urgency tint (M7 DOWNED_LIST): calm amber the instant a teammate goes down, ramping to
# bright red as they near the bleed-out floor; a self-bandaged (halted) pawn is a stabilised cyan.
const REVIVE_CALM_COLOR := Color(1.0, 0.58, 0.16)     # just downed — plenty of bleed-out time left
const REVIVE_URGENT_COLOR := Color(1.0, 0.10, 0.06)   # about to bleed out — revive NOW
const REVIVE_STABLE_COLOR := Color(0.36, 0.78, 1.0)   # self-bandaged: bleed halted, not dying
const PRONE_LIFT := 0.3          # small lift so a flat-lying prone/downed body rests on the ground
const CLIMB_PITCH := 0.32        # rad (~18°) forward lean of a figure climbing a ladder (vs. bolt-upright)
# active vehicle nodes: vid(int) -> Node3D (VehicleKit transport; VehicleState carries no team)
var _vehicle_active: Dictionary = {}
var _vehicle_free_list: Array = []
const VEHICLE_SMOOTH_RATE := 16.0                # higher = snappier; ~1/e catch-up in ~60 ms
var _wreck_mat: StandardMaterial3D = null        # shared burnt-out material for destroyed vehicles
const _WRECK_DEMO_VID := -424242                 # synthetic vid for the --vehicle-test wreck
const _DMG_DEMO_VID := -424243                   # synthetic vid for the --vehicle-test damaged transport
# M11: building_id(int) -> {min,max} world footprint, unioned over the building's lifetime and NEVER
# shrunk, so a COLLAPSE anchors rubble on the ORIGINAL ground centre — not the orphaned upper-floor
# remnant that survives to the fall (that floated the mound; playtest). Persists across rebuilds.
var _building_footprint: Dictionary = {}
# M11 wall edge-alignment: building_id(int) -> {cxmin,cxmax,czmin,czmax} cell footprint, from RAW cells
# (not xforms). Used to push each building wall OUT to the footprint edge (a wall's outward direction
# can't come from its yaw — opposite walls share a yaw). Rebuilt on each full structure rebuild.
var _building_bounds: Dictionary = {}
var _map: MapDef = null   # retained from setup() so a late joiner can anchor rejoin rubble on the static footprint (A3b)

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

# M15: terrain grid the client derives from the same heightmap the server used. null = flat map,
# so the ground falls back to the original single-plane path (backward compatible with pre-M15 maps).
var _terrain: TerrainGrid = null

## Set the terrain grid (null = flat). Call BEFORE setup() builds the ground; setup() reads _terrain
## to choose the flat single-plane path vs the chunked heightmap mesh.
func set_terrain(g) -> void:
	_terrain = g
	if _fx != null:
		_fx.terrain = g   # grenade/rocket/debris cosmetics rest on the terrain surface, not y=0

## Terrain surface height at world (x,z), or 0 on a flat map. Used to seat cosmetic map geometry
## (scenery, point/base markers) ON the hills instead of at the authored y=0 (float/bury otherwise).
func _terrain_y(x: float, z: float) -> float:
	return Terrain.height_at(_terrain, x, z) if _terrain != null else 0.0

## Build the heightmap ground as a grid of MeshInstance3D chunks (TERRAIN_CHUNK cells each) sharing the
## two-tone ground material. Chunking exists only for frustum culling — no custom LOD, no collision.
## Procedural world-space grass shader for the heightmap terrain. Computed in the fragment shader
## (no texture asset, no async NoiseTexture generation -> no grey flash, identical on every GPU):
## multi-octave value noise over world XZ gives per-metre fine speckle (motion reference underfoot)
## + large patches of grass vs dry field; steep normals read as rocky earth. specular_disabled keeps
## it matte (no bluish sky-reflection at grazing angles — the artefact that read as "grey" before).
func _terrain_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode diffuse_burley, specular_disabled;
// Road/sidewalk SURFACE SPLATMAP (R=asphalt, G=sidewalk) painted onto the terrain surface in world
// space so roads conform to the heightmap (no meshes, no z-fight). Unset -> black default -> pure grass.
uniform sampler2D surface_map : hint_default_black, filter_linear, repeat_disable;
uniform vec2 map_origin = vec2(0.0, 0.0);
uniform float map_extent = 1.0;
varying vec3 v_world;
varying vec3 v_wn;
void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
float hash(vec2 p) { p = fract(p * vec2(123.34, 345.45)); p += dot(p, p + 34.345); return fract(p.x * p.y); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i), b = hash(i + vec2(1.0, 0.0)), c = hash(i + vec2(0.0, 1.0)), d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm(vec2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { s += a * vnoise(p); p *= 2.03; a *= 0.5; } return s; }
void fragment() {
	vec2 w = v_world.xz;
	float fine = fbm(w * 0.7);      // ~1.4 m speckle -> per-metre motion reference
	float patch = fbm(w * 0.06);    // ~16 m patches -> grass vs dry field
	vec3 grass_d = vec3(0.16, 0.26, 0.11);
	vec3 grass_l = vec3(0.33, 0.45, 0.19);
	vec3 dry = vec3(0.45, 0.44, 0.22);
	vec3 col = mix(grass_d, grass_l, patch);
	col = mix(col, dry, smoothstep(0.55, 0.92, patch) * 0.55);
	col = mix(col * 0.82, col * 1.16, fine);              // fine light/dark speckle
	float steep = 1.0 - smoothstep(0.62, 0.86, v_wn.y);   // steep slopes -> rocky earth (brown, never red)
	col = mix(col, vec3(0.29, 0.25, 0.19), steep * 0.75);
	// Roads/sidewalks painted onto the surface. smoothstep sharpens the linear-filtered mask into a
	// crisp edge (was a ~0.5 m blur); the asphalt is a FLAT clean grey (only a faint large-scale tone,
	// no fine speckle — the speckle read as "blurry texture" on the road).
	vec2 suv = (w - map_origin) / map_extent;
	vec4 surf = texture(surface_map, suv);
	float road = smoothstep(0.35, 0.65, surf.r);
	float side = smoothstep(0.35, 0.65, surf.g);
	vec3 asphalt = mix(vec3(0.135, 0.135, 0.145), vec3(0.175, 0.175, 0.185), patch);
	col = mix(col, asphalt, road);
	col = mix(col, vec3(0.40, 0.40, 0.42), side);   // muted concrete curb (was stark white)
	ALBEDO = col;
	ROUGHNESS = 1.0;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	return m

func _build_terrain_chunks(mat: Material) -> void:
	var g := _terrain
	var cx := 0
	while cx < g.cols - 1:
		var cz := 0
		while cz < g.rows - 1:
			var x_end := mini(cx + TERRAIN_CHUNK, g.cols - 1)
			var z_end := mini(cz + TERRAIN_CHUNK, g.rows - 1)
			var mi := MeshInstance3D.new()
			mi.mesh = _chunk_mesh(g, cx, cz, x_end, z_end)
			mi.material_override = mat
			add_child(mi)
			cz += TERRAIN_CHUNK
		cx += TERRAIN_CHUNK

## Scatter grass tufts over the terrain as a single MultiMesh (one draw call), on GRASS only:
## every clump inside a building footprint or on a road is skipped, so grass never grows indoors or
## on asphalt. Deterministic (fixed-seed RNG -> identical every run). Denser in the cleared perimeter
## (countryside/fields) than in the village core. Seated on the terrain surface. Cosmetic, no collision.
func _build_grass_foliage(map: MapDef) -> void:
	if _terrain == null:
		return
	# Exclusion AABBs (x0,z0,x1,z1): building footprints (baked) + roads. No objective exclusions —
	# grass under a capture ring is fine.
	var boxes: Array = []
	for b: Dictionary in map.buildings:
		if b.has("footprint"):
			var f: Dictionary = b["footprint"]
			boxes.append(Vector4(float(f["min_x"]), float(f["min_z"]), float(f["max_x"]), float(f["max_z"])))
	# Roads + their painted SIDEWALK border (SIDEWALK_M in map_gen.gen_town_surface_map) so grass never
	# pokes through the white sidewalk.
	var SIDEWALK_M := 2.2
	for rd: Dictionary in map.roads:
		var rmn: Vector3 = rd["min"]
		var rmx: Vector3 = rd["max"]
		boxes.append(Vector4(minf(rmn.x, rmx.x) - SIDEWALK_M, minf(rmn.z, rmx.z) - SIDEWALK_M,
			maxf(rmn.x, rmx.x) + SIDEWALK_M, maxf(rmn.z, rmx.z) + SIDEWALK_M))

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x6A55_1EAF   # fixed -> deterministic scatter
	var half := map.world_half
	var step := 2.1                                   # jittered grid pitch
	var xforms: Array[Transform3D] = []
	var wx := -half + 2.0
	while wx < half - 2.0:
		var wz := -half + 2.0
		while wz < half - 2.0:
			var px := wx + rng.randf_range(-1.1, 1.1)
			var pz := wz + rng.randf_range(-1.1, 1.1)
			wz += step
			# countryside (perimeter) is lush; village interior keeps only scattered tufts
			var country := absf(px) > 108.0 or pz < -92.0 or pz > 80.0
			if rng.randf() > (0.95 if country else 0.55):
				continue
			var blocked := false
			for bx: Vector4 in boxes:
				if px >= bx.x and px <= bx.z and pz >= bx.y and pz <= bx.w:
					blocked = true
					break
			if blocked:
				continue
			# skip steep rock faces (grass thins out on the near-cliff countryside slopes)
			if Terrain.slope_at(_terrain, px, pz) > 34.0:
				continue
			var yaw := rng.randf_range(0.0, TAU)
			var sc := rng.randf_range(0.75, 1.45)
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(sc, sc, sc))
			xforms.append(Transform3D(basis, Vector3(px, _terrain_y(px, pz), pz)))
		wx += step

	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _grass_clump_mesh()
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	# Force a map-spanning AABB: a MultiMesh's auto-bounds can collapse to the origin and then the whole
	# instance is frustum-culled (grass vanishes even underfoot when the camera is far from 0,0). This
	# covers the full terrain so it's never wrongly culled.
	mmi.custom_aabb = AABB(Vector3(-half, -60.0, -half), Vector3(half * 2.0, 120.0, half * 2.0))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # thousands of tufts: shadows too costly
	# NOTE: no visibility_range here — on a MultiMeshInstance3D it measures from the NODE origin (0,0,0),
	# not per-instance, so any camera/player >range from map centre culls the ENTIRE field (the bug that
	# hid all grass at the base ~150 m out). 9.7k instances is one cheap draw; per-instance frustum
	# culling + the map-spanning custom_aabb keep it correct.
	add_child(mmi)

## A single grass tuft: a fan of thin tapered blades, vertex-coloured dark green at the base to a
## lighter green tip. Double-sided + unshaded-ish (matte) so it reads from any angle. ~0.4 m tall.
func _grass_clump_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base_col := Color(0.14, 0.24, 0.09)
	var tip_col := Color(0.46, 0.58, 0.26)   # lighter/yellower tip -> the tuft silhouettes against the ground
	var blades := 5
	for bi in blades:
		var ang := TAU * float(bi) / float(blades) + 0.6
		var off := Vector3(cos(ang), 0.0, sin(ang)) * 0.07
		var lean := Vector3(cos(ang), 0.0, sin(ang)) * 0.14
		var h := 0.42 + 0.18 * float((bi * 7) % 5) / 4.0   # ~0.42-0.6 m: visible, but below crouch height
		var w := Vector3(-sin(ang), 0.0, cos(ang)) * 0.045   # blade half-width, perpendicular
		var p0 := off - w
		var p1 := off + w
		var p2 := off + lean + Vector3(0.0, h, 0.0)
		# UP normal on every vertex so the near-vertical blades catch the sky/sun like the ground does
		# (with no normals the tufts render unlit -> invisible against the grass). SurfaceTool wants the
		# normal set BEFORE each vertex.
		st.set_normal(Vector3.UP)
		st.set_color(base_col); st.add_vertex(p0)
		st.set_normal(Vector3.UP)
		st.set_color(base_col); st.add_vertex(p1)
		st.set_normal(Vector3.UP)
		st.set_color(tip_col);  st.add_vertex(p2)
	var mesh := st.commit()
	var gm := StandardMaterial3D.new()
	gm.vertex_color_use_as_albedo = true
	gm.cull_mode = BaseMaterial3D.CULL_DISABLED       # visible from both sides
	gm.roughness = 1.0
	gm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mesh.surface_set_material(0, gm)
	return mesh

## One chunk mesh: two triangles per grid quad over [x0,x1)×[z0,z1], world-space vertices at sample
## heights. Each vertex carries a planar UV (world XZ mapped 0..1 across the map, exactly like the flat
## PlaneMesh's auto-UVs) so the shared two-tone ground texture tiles — WITHOUT UVs the material samples
## one texel and the whole terrain reads as a single flat colour (no depth cue → looks flat).
func _chunk_mesh(g: TerrainGrid, x0: int, z0: int, x1: int, z1: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var side: float = maxf(float(g.cols - 1) * g.spacing, 1.0)   # map extent; UV 0..1 across it
	for zi in range(z0, z1):
		for xi in range(x0, x1):
			# winding order gives UP-facing normals (verified on-GPU) so the sun lights the TOP surface
			# green — the earlier order produced downward normals (top lit only by bluish ambient -> grey;
			# the underside was correctly lit, which is how we caught it).
			_terr_emit(st, g, side, xi,     zi)
			_terr_emit(st, g, side, xi + 1, zi + 1)
			_terr_emit(st, g, side, xi,     zi + 1)
			_terr_emit(st, g, side, xi,     zi)
			_terr_emit(st, g, side, xi + 1, zi)
			_terr_emit(st, g, side, xi + 1, zi + 1)
	st.index()              # merge shared corner verts -> SMOOTH (per-vertex) normals: no facet shimmer/moiré
	st.generate_normals()   # smooth normals so slopes catch the sun as a soft gradient (reveals elevation)
	return st.commit()

## Emit one terrain vertex (planar UV set BEFORE the vertex, as SurfaceTool requires).
func _terr_emit(st: SurfaceTool, g: TerrainGrid, side: float, xi: int, zi: int) -> void:
	var wx := g.origin_x + float(xi) * g.spacing
	var wz := g.origin_z + float(zi) * g.spacing
	st.set_uv(Vector2((wx - g.origin_x) / side, (wz - g.origin_z) / side))
	st.add_vertex(Vector3(wx, g.sample(xi, zi), wz))

## Build static world geometry once. Call before any update().
func setup(map: MapDef, camera: Camera3D) -> void:
	_camera = camera
	_map = map
	_building_footprint.clear()   # fresh map: drop any prior match's cached footprints
	if _fx != null:
		_fx.terrain = _terrain   # cosmetics rest on the terrain surface (set_terrain may run before _fx exists)
	# Interpret settings.fov as HORIZONTAL fov (BattleBit-style). Godot defaults to KEEP_HEIGHT
	# (vertical), which turns fov=90 into ~121° horizontal on 16:9 — the "fisheye" warp at edges.
	_camera.keep_aspect = Camera3D.KEEP_WIDTH

	# Ground plane
	var side := map.world_half * 2.0
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
	if _terrain == null:
		# Flat map: keep the original single-plane two-tone ground (unchanged, purely visual).
		var ground := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(side, side)
		ground.mesh = plane
		ground.material_override = gmat
		add_child(ground)
	else:
		# M15: heightmap map — replace the flat plane with a chunked terrain mesh, shaded by a
		# WORLD-SPACE procedural grass shader (_terrain_material). Unlike a NoiseTexture2D (generates
		# async -> can flash grey on some drivers) the noise is computed in the fragment shader from
		# world XZ: no asset, no async, identical on every GPU. It gives per-metre fine detail (the
		# near-field MOTION REFERENCE the player was missing on the old flat single-colour terrain),
		# large grass/dry-field patches, rocky earth on steep slopes, and a road/sidewalk SURFACE
		# SPLATMAP (see _terrain_material) so roads conform to the heightmap instead of flat planes.
		var tmat := _terrain_material()
		# Load the splatmap raw via Image (like the heightmap) so the import pipeline can't VRAM-compress
		# and smear the mask channels. Absent/failed -> sampler stays at hint_default_black -> pure grass.
		if map.terrain.has("surface_map") and String(map.terrain["surface_map"]) != "":
			var simg := Image.new()
			var spath := "res://maps/".path_join(String(map.terrain["surface_map"]))
			if simg.load(spath) == OK:
				tmat.set_shader_parameter("surface_map", ImageTexture.create_from_image(simg))
			else:
				push_error("[terrain] failed to load surface_map %s" % spath)
		tmat.set_shader_parameter("map_origin", Vector2(-map.world_half, -map.world_half))
		tmat.set_shader_parameter("map_extent", map.world_half * 2.0)
		_build_terrain_chunks(tmat)
		_build_grass_foliage(map)

	# Roads — flat dark-grey asphalt strips (cosmetic, no collision). TERRAIN maps skip this: roads come
	# from the surface splatmap (conforms to the heightmap instead of burying flat planes under a hill /
	# hovering over a valley). Iterating an empty list on terrain maps emits no road planes or dashes.
	for rd: Dictionary in (map.roads if _terrain == null else []):
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

	# Scenery — procedural trees/rocks (TreeKit/RockKit) + imported GLB props, placed from map JSON
	# (cosmetic, no collision). Trees/rocks are seeded per-placement (stable id+position hash) so each
	# is deterministic but varied across the map.
	for sc: Dictionary in map.scenery:
		var sc_pos: Vector3 = sc["pos"] as Vector3
		var sc_seed := hash(String(sc["id"]) + str(sc_pos))
		var node := SceneryKit.build(String(sc["id"]), map.scenery_palette, String(sc.get("palette", "")), sc_seed)
		if node == null:
			continue
		node.position = Vector3(sc_pos.x, _terrain_y(sc_pos.x, sc_pos.z) + sc_pos.y, sc_pos.z)
		node.rotation.y = float(sc.get("yaw", 0.0))
		var sc_scale := float(sc.get("scale", 1.0))
		if absf(sc_scale - 1.0) > 0.001:
			node.scale = Vector3(sc_scale, sc_scale, sc_scale)
		add_child(node)

	# Capture point markers — just a flat ground RING at the true capture radius (BattleBit zone read).
	# The towering beacon columns were replaced by the screen-space capture-point markers (letter +
	# ownership colour + distance) drawn by HudView.update_objective_markers — see client_main.
	for pt: Dictionary in map.points:
		var pt_pos: Vector3 = pt["pos"] as Vector3
		var pt_radius: float = pt["radius"] as float
		var pt_y := _terrain_y(pt_pos.x, pt_pos.z)
		var marker := _make_ring_marker(pt_radius, 0.6, NEUTRAL_COLOR)
		marker.position = Vector3(pt_pos.x, pt_y + 0.12, pt_pos.z)
		add_child(marker)

	# Base markers — team-coloured ground ring at the true base radius (tall beacon removed too).
	for b: Dictionary in map.bases:
		var b_team: int = b["team"] as int
		var b_pos: Vector3 = b["pos"] as Vector3
		var b_radius: float = b["radius"] as float
		var col: Color = TEAM_COLOR[b_team] if b_team < TEAM_COLOR.size() else NEUTRAL_COLOR
		var b_y := _terrain_y(b_pos.x, b_pos.z)
		var base_marker := _make_ring_marker(b_radius, 0.8, col)
		base_marker.position = Vector3(b_pos.x, b_y + 0.12, b_pos.z)
		add_child(base_marker)

	# Roof-access ladders — the map's climb VOLUMES rendered as visible red ladders (the only way
	# onto the tall buildings' walkable roof decks; see WorldRenderer._make_ladder + tools/map_gen.py).
	for ld: Dictionary in map.ladders:
		var lnode := _make_ladder(ld)
		add_child(lnode)
		var lbid := int(ld.get("building_id", 0))   # so the building's collapse frees this ladder (H1)
		if lbid != 0:
			if not _ladder_nodes.has(lbid):
				_ladder_nodes[lbid] = []
			(_ladder_nodes[lbid] as Array).append(lnode)

	# Tracer pool — thin emissive beams along the aim, hidden until fired.
	for _i in TRACER_POOL:
		var tn := MeshInstance3D.new()
		var tmesh := BoxMesh.new()
		tmesh.size = Vector3(0.06, 0.06, TRACER_LEN)
		tn.mesh = tmesh
		var tmat := fx_material(TRACER_COLOR, true, true, TRACER_COLOR)
		tn.material_override = tmat
		tn.visible = false
		tn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(tn)
		_tracers.append({"node": tn, "mat": tmat, "die": 0.0})

	# Support-link pool — a thin emissive beam (unit length along local -Z, stretched per frame) plus a
	# translucent aura sphere at the target. Hidden until an active support link resolves both endpoints.
	for _i in SUPPORT_POOL:
		var beam := MeshInstance3D.new()
		var bmesh := BoxMesh.new()
		bmesh.size = Vector3(0.07, 0.07, 1.0)   # local -Z spans the link; scaled to the gap each frame
		beam.mesh = bmesh
		var bmat := fx_material(Color.WHITE, true, true)   # colour assigned per link kind each frame
		beam.material_override = bmat
		beam.visible = false
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(beam)
		var aura := MeshInstance3D.new()
		var amesh := SphereMesh.new()
		amesh.radius = 0.5; amesh.height = 1.0
		aura.mesh = amesh
		var amat := fx_material(Color.WHITE, true, true)
		aura.material_override = amat
		aura.visible = false
		aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(aura)
		_support_slots.append({"beam": beam, "beam_mat": bmat, "aura": aura, "aura_mat": amat})

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

## Hide the viewmodel while downed (DBNO): a downed player has no weapon in hand. Composes with the
## photo/scope hides.
func set_viewmodel_downed_hidden(h: bool) -> void:
	_vm_downed_hidden = h
	_apply_vm_visibility()

func _apply_vm_visibility() -> void:
	if _viewmodel != null:
		_viewmodel.visible = not (_vm_photo_hidden or _vm_scope_hidden or _vm_downed_hidden)

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
var _vm_climb_t := 0.0             # 0..1 eased climb/vault-lower amount (gun drops out of view on a ladder/mantle)
var _vm_bob_phase := 0.0           # step cycle phase, advanced by distance travelled
var vm_sprint_test := false        # QA: force the sprint-lowered viewmodel for a screenshot
var vm_climb_test := false         # QA: force the climb/vault-lowered viewmodel for a screenshot
const SPRINT_FOV_ADD := 8.0        # degrees of FOV widening at full sprint (eased via _vm_sprint_t)

## Continuous viewmodel locomotion: a subtle walk bob + an eased sprint-lower, from the predicted
## pawn's motion. Composed in _pose_viewmodel on top of the base placement + any one-shot anim.
func _update_viewmodel_locomotion(pawn: Pawn, dt: float) -> void:
	if pawn == null:
		return
	var vel: Vector3 = pawn.velocity
	var speed := Vector2(vel.x, vel.z).length()
	# Climbing a ladder / auto-vaulting: both hands are on the rungs/ledge, so drop the gun out of the
	# aim (deeper than sprint-lower). Predicted client-side (pawn.climbing/vaulting), so it tracks the
	# local player's own mantle 1:1. Suppresses the sprint-lower + bob so the two don't compound.
	var climbing: bool = vm_climb_test or pawn.climbing or pawn.vaulting
	_vm_climb_t = lerpf(_vm_climb_t, 1.0 if climbing else 0.0, clampf(dt * 9.0, 0.0, 1.0))
	var sprinting: bool = not climbing and (vm_sprint_test or (pawn.grounded and pawn.stance == Stance.STAND and speed > 6.5))
	var speed_norm := 1.0 if vm_sprint_test else clampf(speed / 6.0, 0.0, 1.0)
	speed_norm *= (1.0 - _vm_climb_t)   # damp the walk bob while climbing (feet aren't striding)
	_vm_sprint_t = lerpf(_vm_sprint_t, 1.0 if sprinting else 0.0, clampf(dt * 9.0, 0.0, 1.0))
	_vm_bob_phase = fmod(_vm_bob_phase + speed * dt * 1.7, TAU)
	var bob := ViewmodelAnim.walk_bob(speed_norm, _vm_bob_phase)
	_vm_loco_pos = (bob["pos"] as Vector3) + ViewmodelAnim.SPRINT_LOWER_POS * _vm_sprint_t + ViewmodelAnim.CLIMB_LOWER_POS * _vm_climb_t
	_vm_loco_rot = (bob["rot"] as Vector3) + ViewmodelAnim.SPRINT_LOWER_ROT * _vm_sprint_t + ViewmodelAnim.CLIMB_LOWER_ROT * _vm_climb_t
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
	# Occupant map (pawn id -> seat/heading) so _pose_entity can seat riders instead of standing them
	# upright at the seat. Cross-referenced from the already-replicated VehicleState.seats — no wire.
	_seated_ids = SeatPose.occupants(world_view.vehicles())
	_sync_entity_pool(remotes, local_team, render_delta, now)

	# 1b. Support-link beams (heal/ammo/repair/revive) — resolve giver/target by id from the same
	# snapshot the entity pool just used, so the beams track interpolated positions.
	_update_support_links(world_view, remotes, predictor, now)

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
	_apply_collapse_warnings(now)   # ramping rumble while a nearby building is about to come down (R6)
	_apply_shake(now)      # transient view jitter from collapses / nearby blasts (on top of the camera)
	_pose_viewmodel(now)   # apply any active swing/swap animation on top of the base placement

	# 4. Age out shot tracers + integrate cosmetic rockets + explosions
	_age_tracers(now)
	_age_flashes(now)
	_fx.age_all(now, render_delta)
	_age_casings(now, render_delta)
	_age_corpses(now)
	_age_smokes(now)

	# 5. QA demos: every registered --*-test demo, table-driven (see client/qa_flags.gd). Each
	# _ensure_*_demo self-gates on its own flag, so inactive demos are a cheap early-return.
	_run_demos(now)


## Drive every registry-declared `_ensure_*_demo` (rows with a "demo" method in QaFlags.FLAGS) —
## replaces the old per-flag copy-paste call block. Demo bodies are unchanged; only the wiring is
## table-driven. All demos share one signature: func(now: float) (unused args are underscored).
func _run_demos(now: float) -> void:
	for entry: Dictionary in QaFlags.FLAGS:
		if entry.has("demo"):
			call(String(entry["demo"]), now)


## Visual QA (--armor-demo): once the camera exists, pin LIGHT/MEDIUM/HEAVY dummy soldiers in front
## of it (camera-parented, always in view) for a clean A/B/C armor-diff screenshot.
func _ensure_armor_demo(_now_unused: float) -> void:
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


## Visual QA (--seat-pose-test): pin an upright dummy (left) beside one posed with the SeatPose
## seated transform (right), camera-parented, so a screenshot A/Bs the standing-vs-seated silhouette.
func _ensure_seat_pose_demo(_now_unused: float) -> void:
	if not seat_pose_demo or _seat_pose_demo_done or _camera == null:
		return
	_seat_pose_demo_done = true
	# Left: a normal standing figure (control).
	var standing := CharacterKit.build()
	standing.position = Vector3(-1.9, -1.35, -4.6)
	standing.rotation = Vector3(0, PI, 0)
	_camera.add_child(standing)
	# Right: the same figure with the seated transform (lower + compress + recline) applied.
	var seated := CharacterKit.build()
	var sb := Basis.IDENTITY.rotated(Vector3.UP, PI)          # face the camera (matches standing)
	sb = sb.rotated(sb.x, -SeatPose.SIT_RECLINE)
	seated.transform.basis = sb
	seated.scale = Vector3(1.0, SeatPose.SIT_HEIGHT_SCALE, 1.0)
	seated.position = Vector3(-0.5, -1.35 + SeatPose.SIT_LIFT, -4.6)
	_camera.add_child(seated)


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
	# Own muzzle flash sits ~0.5 m from the camera, so the full-size plate filled the lower-right of the
	# screen. Shrink it hard for the first-person shot (remote shots keep full size — see tracer_from).
	_spawn_tracer(origin, fwd, now, LOCAL_FLASH_SCALE)


## Cosmetic tracer for a REMOTE pawn's shot (from a server SHOT_FX): a beam from the shooter's
## muzzle along their aim, so other players' fire is readable instead of looking like statues.
func tracer_from(origin: Vector3, dir: Vector3, now: float) -> void:
	if dir.length() < 0.001:
		return
	_spawn_tracer(origin, dir.normalized(), now)


# First-person muzzle flash spawns right in front of the camera, so it needs to be a fraction of the
# world-space plate size a distant remote shot uses, or it fills the screen.
const LOCAL_FLASH_SCALE := 0.3

func _spawn_tracer(origin: Vector3, fwd: Vector3, now: float, flash_scale: float = 1.0) -> void:
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
	_spawn_flash(origin, fwd, now, flash_scale)


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


func _spawn_flash(origin: Vector3, fwd: Vector3, now: float, scale: float = 1.0) -> void:
	if _flashes.is_empty():
		return
	var up := Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var f: Dictionary = _flashes[_flash_idx]
	_flash_idx = (_flash_idx + 1) % _flashes.size()
	var node: MeshInstance3D = f["node"]
	# Scale the pooled plate per-spawn (small for the first-person shot, full for distant remote shots).
	node.global_transform = Transform3D(Basis.looking_at(fwd, up).scaled(Vector3.ONE * scale), origin)
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
## soft unshaded puffs scattered in the zone; opacity is driven per-frame by SmokeCloud.envelope in
## _age_smokes (billow-in / hold / fade-out). Deterministic offsets (golden-angle spiral) so the
## cloud reads the same every time; capped at SMOKE_MAX_CLOUDS (oldest dropped) to bound mesh count.
func spawn_smoke(pos: Vector3, radius: float, duration: float, now: float, vel: Vector3 = Vector3.ZERO) -> void:
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
		var mat := fx_material(Color(SMOKE_COLOR.r, SMOKE_COLOR.g, SMOKE_COLOR.b, 0.0), true)
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(node)
		mats.append(mat)
		bases.append(node.position)
	# Canister kinematics so the cloud follows the grenade's fall/roll (C3): pos+vel integrated per
	# frame under the shared Grenade model, clamped to the ground. Zero vel -> the cloud stays put.
	_smokes.append({"root": root, "mats": mats, "born": now, "dur": duration, "base": bases,
		"pos": pos, "vel": vel, "t": now})


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
		# Follow the canister: integrate its fall under the shared Grenade model and rest it on the
		# ground, so the cloud trails the grenade wherever it flew before settling (C3). Skips work
		# once the canister is at rest (vel zero on the ground).
		var vel: Vector3 = s["vel"]
		if vel != Vector3.ZERO:
			var dt: float = maxf(0.0, now - float(s["t"]))
			var step := Grenade.integrate(s["pos"], vel, dt)
			var np: Vector3 = step["pos"]
			var nv: Vector3 = step["vel"]
			if np.y <= 0.0:
				np.y = 0.0
				nv = Vector3.ZERO
			s["pos"] = np; s["vel"] = nv
			root.position = np
		s["t"] = now
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
## Replace the active support links from a server SUPPORT_LIST. Raw ids+kind only; positions are
## resolved per render frame in _update_support_links (entities interpolate between sim ticks).
func set_support_links(list: Array) -> void:
	_support_links = list

## Ingest the latest DOWNED_LIST: map id -> {frac 0..1, halted}. Drives the downed-teammate revive
## marker's colour + bob urgency so you can triage who's about to bleed out. View-only.
func set_downed_urgency(list: Array) -> void:
	_downed_urgency.clear()
	for e in list:
		_downed_urgency[int(e["id"])] = {"frac": float(int(e["frac"])) / 255.0, "halted": bool(e["halted"])}

## Resolve each active support link's endpoints from the current snapshot and drive the beam + aura
## pool. A link whose giver OR target isn't visible this frame (left interest, dead) is simply not
## drawn. Endpoint = chest height (pos + SUPPORT_CHEST_Y); for the local player we use the predicted
## pawn so a beam from us doesn't lag the camera.
func _update_support_links(world_view: WorldView, remotes: Dictionary, predictor: Prediction, now: float) -> void:
	var slot := 0
	if not _support_links.is_empty():
		var lid := world_view.local_id()
		var local_pos := predictor.predicted.pos if predictor.predicted != null else Vector3.INF
		var vehicles: Dictionary = world_view.vehicles()
		for link: Dictionary in _support_links:
			if slot >= _support_slots.size():
				break
			var a := _resolve_support_pos(int(link["giver"]), lid, local_pos, remotes, vehicles)
			var b := _resolve_support_pos(int(link["target"]), lid, local_pos, remotes, vehicles)
			if not a.is_finite() or not b.is_finite():
				continue
			a.y += SUPPORT_CHEST_Y
			b.y += SUPPORT_CHEST_Y
			_draw_support_slot(_support_slots[slot], a, b, int(link["kind"]), now)
			slot += 1
	# Hide unused slots.
	for i in range(slot, _support_slots.size()):
		_support_slots[i]["beam"].visible = false
		_support_slots[i]["aura"].visible = false

## Position of an entity id this frame, or Vector3.INF if not visible. Pawns come from `remotes`
## (or the predicted local pawn); vehicle-range ids come from the vehicle pool.
func _resolve_support_pos(id: int, local_id: int, local_pos: Vector3, remotes: Dictionary, vehicles: Dictionary) -> Vector3:
	if id == local_id:
		return local_pos
	if remotes.has(id):
		return (remotes[id] as EntityState).pos
	if vehicles.has(id):
		return (vehicles[id] as VehicleState).pos
	return Vector3.INF

func _draw_support_slot(s: Dictionary, a: Vector3, b: Vector3, kind: int, now: float) -> void:
	# Revive draws no support FX — the downed teammate's red indicator marker already shows it (owner
	# asked to drop the extra revive beam/ball/cross). Heal/ammo/repair still draw their beam + aura.
	if kind == SUPPORT_REVIVE_KIND:
		s["beam"].visible = false
		s["aura"].visible = false
		return
	var dir := b - a
	var dist := dir.length()
	var beam: MeshInstance3D = s["beam"]
	if dist < 0.15:
		beam.visible = false   # endpoints coincide — nothing meaningful to draw
	else:
		var mid := (a + b) * 0.5
		var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 * dist else Vector3.RIGHT
		# Bake the length into the basis (LOCAL z-scale: B * S). Basis.scaled() is S * B — a GLOBAL
		# scale — which only stretched the beam correctly when the link happened to run along world Z;
		# an east–west heal beam drew as a ~1 m stub bloated sideways, diagonals as skewed slabs.
		beam.global_transform = Transform3D(Basis.looking_at(dir / dist, up) * Basis.from_scale(Vector3(1.0, 1.0, dist)), mid)
		var col: Color = SUPPORT_COLORS.get(kind, Color.WHITE)
		var bmat: StandardMaterial3D = s["beam_mat"]
		# Gentle flow pulse so the link reads as "active" rather than a static line.
		var pulse := 0.55 + 0.30 * (0.5 + 0.5 * sin(now * 7.0))
		bmat.albedo_color = Color(col.r, col.g, col.b, pulse)
		bmat.emission = col
		beam.visible = true
	# Target aura — a soft translucent sphere that breathes.
	var aura: MeshInstance3D = s["aura"]
	var grow := 1.0 + 0.18 * sin(now * 5.0)
	aura.global_transform = Transform3D(Basis().scaled(Vector3(grow, grow, grow)), b)
	var acol: Color = SUPPORT_COLORS.get(kind, Color.WHITE)
	var amat: StandardMaterial3D = s["aura_mat"]
	amat.albedo_color = Color(acol.r, acol.g, acol.b, 0.22)
	amat.emission = acol
	aura.visible = true

# Supply bags (M7): view-only glyph + resupply/heal aura ring. The radius is the server's real dispense
# range from data/gadgets.json — both the medkit and ammobag use bag_radius = 3.0 m — mirrored here so
# the ring matches gameplay. Amber = ammo, green = medic (BattleBit-style).
const BAG_SUPPLY_RADIUS := 3.0
const BAG_AMMO_COLOR := Color(0.92, 0.66, 0.16)   # amber (matches the Support ammo-give beam)
const BAG_MED_COLOR := Color(0.30, 0.80, 0.38)    # medic green

var _bag_glyph_tex := {}   # is_ammo(bool) -> ImageTexture, built once and shared across all bags

## Replace the rendered gadget set with `list` (each {kind, pos, face}; bags also carry `subtype`
## = Gadget.KIND_HEAL/KIND_AMMO and `team`). `local_team` is the viewer's team so the resupply/heal
## ground ring draws only for FRIENDLY bags (-1 = team unknown -> no ring). Cheap full rebuild — the
## server only resends on change and gadgets are few. C4 sticks a charge with a blinking light; a mine
## is a small directional claymore; a bag is an amber ammo box / green medic bag with a top glyph.
func set_gadgets(list: Array, local_team: int = -1) -> void:
	for n in _gadget_nodes:
		(n as Node3D).queue_free()
	_gadget_nodes.clear()
	for g: Dictionary in list:
		var pos: Vector3 = g["pos"]
		if not pos.is_finite():
			continue
		var kind := int(g["kind"])
		var subtype := int(g.get("subtype", -1))
		var node := _make_gadget(kind, g.get("face", Vector3.ZERO), subtype)
		node.position = pos
		add_child(node)
		_gadget_nodes.append(node)
		# Friendly-only resupply/heal ring, on the ground at the bag's true dispense radius.
		if kind == GadgetList.BAG and local_team >= 0 and int(g.get("team", -1)) == local_team:
			var col: Color = BAG_AMMO_COLOR if subtype == Gadget.KIND_AMMO else BAG_MED_COLOR
			var ring := _make_ring_marker(BAG_SUPPLY_RADIUS, 0.12, col)
			# The bag is deployed on the ground, so pos.y is ground height; lift the ring a hair to avoid z-fighting.
			ring.position = Vector3(pos.x, pos.y + 0.06, pos.z)
			add_child(ring)
			_gadget_nodes.append(ring)


func _make_gadget(kind: int, face: Vector3, subtype: int = -1) -> Node3D:
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
		GadgetList.BAG:    # supply crate: amber ammo box or green medic bag, with a readable top glyph
			root.name = "Bag"
			var is_ammo := subtype == Gadget.KIND_AMMO
			var crate := MeshInstance3D.new()
			var cmesh := BoxMesh.new(); cmesh.size = Vector3(0.55, 0.4, 0.4)
			crate.mesh = cmesh; crate.position = Vector3(0, 0.2, 0)
			# Tint the box itself so it reads even edge-on: dark amber for ammo, medic green for heal.
			var body_col: Color = Color(0.36, 0.27, 0.10) if is_ammo else Color(0.16, 0.44, 0.24)
			var bmat := StandardMaterial3D.new(); bmat.albedo_color = body_col; bmat.roughness = 0.9
			crate.material_override = bmat; crate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(crate)
			# Camera-facing glyph floating just above the lid: ammo icon or green medic cross.
			var glyph := _make_bag_glyph(is_ammo)
			glyph.position = Vector3(0, 0.62, 0)
			root.add_child(glyph)
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


## A small camera-facing glyph billboarded above a supply bag: an amber ammo icon (three rounds) or a
## green medic cross. Drawn into a procedurally-generated transparent texture (no asset -> deterministic
## on every GPU, no grey-flash) on an unshaded quad. Purely presentational.
func _make_bag_glyph(is_ammo: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "BagGlyph"
	var q := QuadMesh.new(); q.size = Vector2(0.32, 0.32)
	mi.mesh = q
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_texture = _bag_glyph_texture(is_ammo)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST   # crisp pixel glyph
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _bag_glyph_texture(is_ammo: bool) -> ImageTexture:
	if not _bag_glyph_tex.has(is_ammo):
		_bag_glyph_tex[is_ammo] = ImageTexture.create_from_image(_bag_glyph_image(is_ammo))
	return _bag_glyph_tex[is_ammo]

## Build the 32×32 RGBA glyph: a soft rounded plate (green for medic, dark for ammo) with either a
## white cross (heal) or three amber rounds (ammo) painted on top. Pure pixel-fill — no font/asset.
func _bag_glyph_image(is_ammo: bool) -> Image:
	var s := 32
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var plate: Color = Color(0.16, 0.12, 0.07, 0.86) if is_ammo else Color(0.14, 0.52, 0.26, 0.86)
	for y in range(s):
		for x in range(s):
			if x < 2 or x > 29 or y < 2 or y > 29:
				continue
			# clip the four corners so the plate reads as a rounded square, not a hard block
			if (x < 6 or x > 25) and (y < 6 or y > 25):
				var cx := 6 if x < 6 else 25
				var cy := 6 if y < 6 else 25
				if Vector2(x - cx, y - cy).length() > 4.0:
					continue
			img.set_pixel(x, y, plate)
	if is_ammo:
		var amber := Color(0.96, 0.72, 0.22, 1.0)
		for cx in [9, 16, 23]:
			for y in range(8, 25):
				var hw := (y - 8) if y < 11 else 2   # pointed tip tapering into a round body
				for x in range(cx - hw, cx + hw + 1):
					if x >= 0 and x < s:
						img.set_pixel(x, y, amber)
	else:
		var white := Color(0.97, 0.98, 0.97, 1.0)
		for y in range(6, 27):
			for x in range(13, 20):
				img.set_pixel(x, y, white)   # vertical bar of the cross
		for x in range(6, 27):
			for y in range(13, 20):
				img.set_pixel(x, y, white)   # horizontal bar of the cross
	return img


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


## Visual QA (--downed-urgency-test): four downed dummies side-on, each at a different bleed-out
## urgency so the marker colour + bob ramp is visible at a glance — left to right: just-downed (calm
## amber, slow bob), mid (orange), near-death (bright red, fast/high bob), and self-bandaged
## (stabilised cyan, calm). Mirrors the live DOWNED_LIST branch's colour + urgency_bob.
func _ensure_downed_urgency_demo(now: float) -> void:
	if not downed_urgency_demo or _camera == null:
		return
	# [frac, halted, local-x]
	var specs := [[1.0, false, -3.0], [0.5, false, -1.0], [0.0, false, 1.0], [0.6, true, 3.0]]
	if _downed_urgency_markers.is_empty():
		for spec in specs:
			var dummy := CharacterKit.build()
			dummy.position = Vector3(spec[2], -1.5, -5.0)
			dummy.rotation = Vector3(-PI * 0.5, 0.0, 0.0)   # on its back (downed = face-up)
			_camera.add_child(dummy)
			var mk := _make_friend_marker()
			_camera.add_child(mk)
			_downed_urgency_markers.append(mk)
	for i in range(specs.size()):
		var frac: float = specs[i][0]
		var halted: bool = specs[i][1]
		var mk: MeshInstance3D = _downed_urgency_markers[i]
		(mk.material_override as StandardMaterial3D).albedo_color = \
			REVIVE_STABLE_COLOR if halted else REVIVE_CALM_COLOR.lerp(REVIVE_URGENT_COLOR, 1.0 - frac)
		mk.position = Vector3(specs[i][2], -0.2 + RevivePulse.urgency_bob(now, frac, halted), -5.0)


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
	# team 0 with local_team 0 -> the bags read as friendly so their resupply/heal rings render.
	set_gadgets([
		{"kind": GadgetList.C4, "pos": base - right * 2.1, "face": Vector3.ZERO},
		{"kind": GadgetList.MINE, "pos": base - right * 0.7, "face": -fwd},
		{"kind": GadgetList.BAG, "pos": base + right * 0.7, "face": Vector3.ZERO,
			"subtype": Gadget.KIND_AMMO, "team": 0},
		{"kind": GadgetList.BAG, "pos": base + right * 2.1, "face": Vector3.ZERO,
			"subtype": Gadget.KIND_HEAL, "team": 0},
	], 0)


## Visual QA (--support-test): camera-parented giver + target dummies linked by a live support beam +
## aura (cycling kind so all four colours — heal/ammo/repair/revive — show). Camera-parented (like the
## armor demo) so it's always in view regardless of where/when the player spawned.
func _ensure_support_demo(now: float) -> void:
	if not support_demo or _camera == null:
		return
	if not _support_demo_done:
		_support_demo_done = true
		var giver := CharacterKit.build()
		giver.position = Vector3(-1.6, -1.4, -6.0)   # camera-local: lowered to show feet, 6 m ahead
		giver.rotation = Vector3(0, PI * 0.5, 0)      # face the target across the gap
		_camera.add_child(giver)
		var target := CharacterKit.build()
		target.position = Vector3(1.6, -1.4, -6.0)
		target.rotation = Vector3(0, -PI * 0.5, 0)
		_camera.add_child(target)
		# Beam: a box whose length runs along local X, spanning the two chests; scaled per frame.
		_support_demo_beam = MeshInstance3D.new()
		var bmesh := BoxMesh.new(); bmesh.size = Vector3(1.0, 0.08, 0.08)
		_support_demo_beam.mesh = bmesh
		_support_demo_beam_mat = fx_material(Color.WHITE, true, true)
		_support_demo_beam.material_override = _support_demo_beam_mat
		_support_demo_beam.position = Vector3(0.0, -1.4 + SUPPORT_CHEST_Y, -6.0)
		_support_demo_beam.scale = Vector3(3.2, 1.0, 1.0)   # span between the two chests
		_support_demo_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_camera.add_child(_support_demo_beam)
		_support_demo_aura = MeshInstance3D.new()
		var amesh := SphereMesh.new(); amesh.radius = 0.5; amesh.height = 1.0
		_support_demo_aura.mesh = amesh
		_support_demo_aura_mat = fx_material(Color.WHITE, true, true)
		_support_demo_aura.material_override = _support_demo_aura_mat
		_support_demo_aura.position = Vector3(1.6, -1.4 + SUPPORT_CHEST_Y, -6.0)
		_support_demo_aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_camera.add_child(_support_demo_aura)
	var kind := int(now / 1.6) % 4   # cycle heal -> ammo -> repair -> revive
	var col: Color = SUPPORT_COLORS.get(kind, Color.WHITE)
	var pulse := 0.55 + 0.30 * (0.5 + 0.5 * sin(now * 7.0))
	_support_demo_beam_mat.albedo_color = Color(col.r, col.g, col.b, pulse)
	_support_demo_beam_mat.emission = col
	var grow := 1.0 + 0.18 * sin(now * 5.0)
	_support_demo_aura.scale = Vector3(grow, grow, grow)
	_support_demo_aura_mat.albedo_color = Color(col.r, col.g, col.b, 0.22)
	_support_demo_aura_mat.emission = col


## --buildsite-test QA: a camera-parented ghost FOB build site whose shovel fill cycles 0..1 so a
## screenshot shows the under-construction look (translucent silhouette + rising amber fill).
func _ensure_buildsite_demo(now: float) -> void:
	if not buildsite_demo or _camera == null:
		return
	if not _buildsite_demo_done:
		_buildsite_demo_done = true
		# Type 23 = "fob" (the large squad bunker) — the most representative build site.
		var rec := {"type": 23, "cell": Vector3i(0, 0, 0), "yaw": 0, "build_progress": 0,
			"under_construction": 1}
		var entry := _build_buildsite_ghost(rec)
		var root: Node3D = entry["root"]
		# Re-parent under the camera: in front, lowered to the ground, and yawed for a 3/4 read of the
		# bunker silhouette + the rising fill.
		remove_child(root)
		root.position = Vector3(0.2, -1.7, -6.0)
		root.rotation = Vector3(0.0, PI * 0.15, 0.0)
		_camera.add_child(root)
		_buildsite_demo_node_entry = entry
	if _buildsite_demo_node_entry != null:
		# Hold a fixed, clearly-partial fill so the screenshot deterministically shows the rising
		# scaffold (the live in-game site animates with real shovel progress instead).
		_set_buildsite_fraction(_buildsite_demo_node_entry, 0.6)


# =============================================================================
#  Explosion VFX (M7) — driven by the server DETONATION event (cosmetic).
# =============================================================================
## Thin delegates: the public FX API stays on the renderer (client_main + tests call these);
## the pools and their logic live in client/fx_pool.gd.
func fire_rocket(origin: Vector3, dir: Vector3, now: float) -> void:
	_fx.fire_rocket(origin, dir, now)

func cull_rockets_near(pos: Vector3, radius: float) -> void:
	_fx.cull_rockets_near(pos, radius)

func throw_grenade(origin: Vector3, vel: Vector3, kind: int, now: float, friendly: bool = false) -> void:
	_fx.throw_grenade(origin, vel, kind, now, friendly)

## Give the thrown-grenade cosmetic pool the client's collision store so it bounces off walls (C4).
func set_grenade_collision(store) -> void:
	_fx.struct_store = store

func live_grenade_positions() -> Array:
	return _fx.live_grenade_positions()

func spawn_explosion(pos: Vector3, kind: int, now: float) -> void:
	_fx.spawn_explosion(pos, kind, now)

func spawn_impact(pos: Vector3, kind: int, now: float) -> void:
	_fx.spawn_impact(pos, kind, now)

static func fx_material(albedo: Color, alpha := false, emissive := false,
		emission := Color.BLACK, energy := 1.0) -> StandardMaterial3D:
	return FxPoolRef.fx_material(albedo, alpha, emissive, emission, energy)


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
## Local gun's casing — framed near the camera's ejection port (pops up-and-right, briefly visible
## before falling away; a pure rightward eject leaves the frame instantly).
func eject_casing(now: float) -> void:
	if _camera == null:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	var right := cb.basis.x.normalized()
	var up := cb.basis.y.normalized()
	var fwd := (-cb.basis.z).normalized()
	_spawn_casing(cb.origin + right * 0.22 + up * (-0.10) + fwd * 0.42, right, up, fwd, now)

## Remote shooter's casing, driven by SHOT_FX origin+dir (no shooter_id needed). Ejects to the right
## of the aim direction at the muzzle. dir = shot direction; a horizontal "right" is derived from it.
func eject_casing_at(origin: Vector3, dir: Vector3, now: float) -> void:
	if not origin.is_finite() or not dir.is_finite():
		return
	var fwd := dir.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	if right.length() < 0.01:
		right = Vector3(1, 0, 0)   # near-vertical aim fallback
	_spawn_casing(origin + right * 0.2 + Vector3(0, 0.05, 0), right, Vector3.UP, fwd, now)

func _spawn_casing(pos: Vector3, right: Vector3, up: Vector3, fwd: Vector3, now: float) -> void:
	_casing_i += 1
	var jitter := float((_casing_i % 5) - 2) * 0.4   # -0.8..0.8 spread, no per-frame RNG
	var node := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.014; cyl.bottom_radius = 0.014; cyl.height = 0.07
	node.mesh = cyl
	node.material_override = _casing_material()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = pos
	node.rotation = Vector3(0.0, 0.0, PI * 0.5)   # lay it on its side initially
	add_child(node)
	# Pop up-and-right so the brass arcs out of the port rather than shooting straight sideways.
	var vel := right * (1.4 + jitter) + up * 2.8 + fwd * (-0.3)
	var spin := Vector3(8.0 + jitter, 5.0, 11.0)   # rad/s tumble
	_casings.append({"node": node, "vel": vel, "spin": spin, "die": now + CASING_TTL})
	while _casings.size() > CASING_MAX:
		var old: Dictionary = _casings.pop_front()
		(old["node"] as Node3D).queue_free()

## Visual QA (--casing-test): eject a local casing + a remote-path casing (downrange) every ~0.12 s so
## a screenshot catches brass mid-air from both the local-gun and the SHOT_FX (remote) paths.
func _ensure_casing_demo(now: float) -> void:
	if not casing_demo or _camera == null or now < _casing_demo_next:
		return
	_casing_demo_next = now + 0.12
	eject_casing(now)
	var cb := _camera.global_transform
	if cb.origin.is_finite():
		var fwd := (-cb.basis.z).normalized()
		var muzzle := cb.origin + fwd * 4.0 + Vector3(0, 0.3, 0)   # stand in for a remote shooter downrange
		eject_casing_at(muzzle, fwd, now)

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
		_spawn_footstep_fx(at, 0.4 + 0.2 * float(j), now, Stance.STAND)


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
				# Colour + bob track bleed-out urgency (DOWNED_LIST): amber -> red as they near the
				# floor; stabilised cyan + calm bob once self-bandaged. Falls back to the flat revive
				# tint + calm bob if the urgency packet hasn't arrived yet for this id.
				var u: Dictionary = _downed_urgency.get(int(id), {})
				if u.is_empty():
					mk_mat.albedo_color = REVIVE_MARKER_COLOR
					marker.position = Vector3(es.pos.x, es.pos.y + FRIEND_MARKER_Y + RevivePulse.bob(now), es.pos.z)
				else:
					var frac: float = u["frac"]
					var halted: bool = u["halted"]
					mk_mat.albedo_color = REVIVE_STABLE_COLOR if halted else REVIVE_CALM_COLOR.lerp(REVIVE_URGENT_COLOR, 1.0 - frac)
					var bob: float = RevivePulse.urgency_bob(now, frac, halted)
					marker.position = Vector3(es.pos.x, es.pos.y + FRIEND_MARKER_Y + bob, es.pos.z)
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
	if _seated_ids.has(id):
		# Seat-slaved to a vehicle hull: the replicated position rides the vehicle, not legs — a
		# moving transport otherwise trailed sprint dust + ~8 footfalls/sec per occupant.
		_step_prev[id] = es.pos
		_step_accum[id] = 0.0
		return
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
		_spawn_footstep_fx(es.pos, r["intensity"], now, es.stance)


## Estimate a remote's airborne state from its interpolated vertical motion (no `grounded` on the wire)
## and kick a dust burst when it lands from a fall. Called every frame per remote so the vy estimate is
## continuous (even across pose branches). Returns true while airborne (drives the jump/fall pose).
func _update_airborne(id: int, es: EntityState, dt: float, now: float) -> bool:
	if _seated_ids.has(id):
		# Riding a vehicle: vertical hull motion is not a jump/fall — a transport dropping off a
		# ledge otherwise fired a landing dust burst + LAND footstep at every seated occupant.
		_air_y[id] = es.pos.y
		_air_vy[id] = 0.0
		_air_fell[id] = false
		return false
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
		_spawn_footstep_fx(es.pos, 1.0, now, es.stance, FootstepAudio.LAND)   # strong dust burst at the feet on touchdown
	return absf(vy) > AIR_JUMP_VY and not es.climbing

## Kick the local viewmodel down on a hard landing (client_main calls this off the predicted pawn's
## airborne->grounded transition). Decays back in _update_viewmodel_locomotion. View-only.
func play_land_dip(strength: float) -> void:
	_vm_land_dip = maxf(_vm_land_dip, clampf(strength, 0.0, 1.0) * MAX_LAND_DIP)

## Arm a brief fire-recoil twitch on a remote pawn's body (from SHOT_FX shooter_id) so a firing
## enemy's body flinches instead of standing statue-still behind its muzzle flash. View-only.
func flash_fire(id: int, now: float) -> void:
	if id > 0:
		_fire_recoil[id] = now + FIRE_RECOIL_TTL

## Forward flinch pitch (rad) for a pawn's standing pose: a stagger that eases out, 0 when not hit.
func _flinch_pitch(id: int) -> float:
	var expire: float = _flinch.get(id, 0.0)
	if _now >= expire:
		return 0.0
	var t := clampf((expire - _now) / FLINCH_TTL, 0.0, 1.0)   # 1 at the hit -> 0 at the end
	return FLINCH_PITCH * t   # positive = forward stagger (b.x pitch: +forward, -back)

## Signed recoil pitch (rad) for a pawn's standing pose: a backward lean that eases out, 0 when idle.
func _fire_recoil_pitch(id: int) -> float:
	var expire: float = _fire_recoil.get(id, 0.0)
	if _now >= expire:
		return 0.0
	var rt := clampf((expire - _now) / FIRE_RECOIL_TTL, 0.0, 1.0)   # 1 at the shot -> 0 at the end
	return -FIRE_RECOIL_PITCH * rt   # negative = lean back (b.x pitch: +forward, -back)

## Arm a remote-reload pose lasting `dur` seconds (RELOAD_FX duration). View-only; ignored for dur<=0.
func remote_reload(id: int, now: float, dur: float) -> void:
	if id > 0 and dur > 0.0:
		_reload_until[id] = now + dur

func _is_reloading(id: int) -> bool:
	return _now < float(_reload_until.get(id, 0.0))

## Forward pitch (rad) for a reloading pawn's standing pose: a steady head-down-over-the-gun lean with
## a slow work-the-mag bob. Positive = forward (b.x pitch: +forward). 0 when not reloading.
func _reload_pitch(id: int) -> float:
	if not _is_reloading(id):
		return 0.0
	return RELOAD_PITCH + RELOAD_BOB * sin(_now * TAU * RELOAD_BOB_HZ)

## Arm a brief melee-swing lunge on a remote pawn's body (from MELEE_FX). View-only.
func remote_melee(id: int, now: float) -> void:
	if id > 0:
		_melee_swing[id] = now + MELEE_SWING_TTL

## Arm a brief mantle/clamber pose on a remote pawn's body (from VAULT_FX). View-only.
func remote_vault(id: int, now: float) -> void:
	if id > 0:
		_vault_until[id] = now + VAULT_POSE_TTL

func _is_vaulting_pose(id: int) -> bool:
	return _now < float(_vault_until.get(id, 0.0))

func _is_meleeing(id: int) -> bool:
	return _now < float(_melee_swing.get(id, 0.0))

## Forward lunge pitch (rad) for a swinging pawn's standing pose: peaks early then eases out. 0 idle.
func _melee_pitch(id: int) -> float:
	var expire: float = _melee_swing.get(id, 0.0)
	if _now >= expire:
		return 0.0
	var t := clampf((expire - _now) / MELEE_SWING_TTL, 0.0, 1.0)   # 1 at swing start -> 0 at end
	# Symmetric lunge arc: 0 at the start, peak mid-swing, back to 0 — a single forward strike.
	return MELEE_SWING_PITCH * sin(PI * (1.0 - t))


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
		footstep.emit(eye, r["intensity"], FootstepAudio.action_from(r["intensity"], pawn.stance))


## Kick a dust scuff at a footfall and emit a spatial footstep sound. Dust scales a touch with speed.
func _spawn_footstep_fx(pos: Vector3, intensity: float, now: float, stance: int, action: int = -1) -> void:
	if not pos.is_finite():
		return
	var at := Vector3(pos.x, pos.y + 0.05, pos.z)   # at the feet, just clear of the ground
	_fx.spawn_puff(at, lerpf(0.22, 0.42, intensity), FOOTSTEP_PUFF_TTL, now, FOOTSTEP_DUST_COLOR)
	var act := action if action >= 0 else FootstepAudio.action_from(intensity, stance)
	footstep.emit(at, intensity, act)


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


## Visual QA (--glbshoot-test): two GLB soldiers side-by-side — left plays the resting `holding-both`
## clip, right plays the authored `holding-both-shoot` (recoil) clip — so the shoot pose is verifiable
## independent of the use_models setting. Builds GLB directly (not the procedural kit).
func _ensure_glbshoot_demo(now: float) -> void:
	if not glbshoot_demo or _glbshoot_demo_done or _camera == null or now < 1.0:
		return
	_glbshoot_demo_done = true
	# Both placed left of centre so the local viewmodel (bottom-right) doesn't occlude them.
	for spec in [{"x": -2.4, "clip": "holding-both"}, {"x": -0.7, "clip": "holding-both-shoot"}]:
		var dummy := GlbCharacterKit.build()
		dummy.position = Vector3(float(spec["x"]), -1.5, -2.8)
		dummy.rotation.y = PI   # face the camera
		_camera.add_child(dummy)
		CharacterDriver.drive(GlbCharacterKit.anim_player(dummy), String(spec["clip"]), true)


## Visual QA (--firepose-test): upright dummy next to one frozen at peak fire-recoil (lean back).
func _ensure_firepose_demo(now: float) -> void:
	if not firepose_demo or _firepose_demo_done or _camera == null or now < 1.0:
		return
	_firepose_demo_done = true
	var upright := CharacterKit.build()
	upright.position = Vector3(-0.8, -1.1, -3.0)
	_camera.add_child(upright)
	var firing := CharacterKit.build()
	firing.transform.basis = Basis.IDENTITY.rotated(Vector3(1, 0, 0), -FIRE_RECOIL_PITCH)   # peak lean-back
	firing.position = Vector3(0.8, -1.1, -3.0)
	_camera.add_child(firing)


## Visual QA (--flinch-test): upright dummy next to one frozen at peak hit-flinch (forward stagger).
func _ensure_flinch_demo(now: float) -> void:
	if not flinch_demo or _flinch_demo_done or _camera == null or now < 1.0:
		return
	_flinch_demo_done = true
	var upright := CharacterKit.build()
	upright.position = Vector3(-0.8, -1.1, -3.0)
	_camera.add_child(upright)
	var hit := CharacterKit.build()
	hit.transform.basis = Basis.IDENTITY.rotated(Vector3(1, 0, 0), FLINCH_PITCH)   # peak forward stagger
	hit.position = Vector3(0.8, -1.1, -3.0)
	_camera.add_child(hit)


## Visual QA (--remote-reload-test): upright dummy next to one pitched forward at the reload lean
## (head down over the gun) — the same forward pose the procedural body holds while reloading.
func _ensure_reloadpose_demo(now: float) -> void:
	if not reloadpose_demo or _reloadpose_demo_done or _camera == null or now < 1.0:
		return
	_reloadpose_demo_done = true
	var upright := CharacterKit.build()
	upright.position = Vector3(-0.8, -1.1, -3.0)
	_camera.add_child(upright)
	var reloading := CharacterKit.build()
	reloading.transform.basis = Basis.IDENTITY.rotated(Vector3(1, 0, 0), RELOAD_PITCH)   # forward lean
	reloading.position = Vector3(0.8, -1.1, -3.0)
	_camera.add_child(reloading)


## Visual QA (--held-weapon-test): five soldiers in a row, side-on to the camera, each carrying a
## different weapon (AR/SMG/DMR/RPG/PISTOL) so the per-weapon GunMount silhouettes are comparable.
func _ensure_heldweapon_demo(now: float) -> void:
	if not heldweapon_demo or _heldweapon_demo_done or _camera == null or now < 1.0:
		return
	_heldweapon_demo_done = true
	var weapons := [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.RPG, Weapon.PISTOL]
	for i in weapons.size():
		var dummy := CharacterKit.build()
		dummy.position = Vector3(-2.6 + 1.3 * float(i), -1.4, -4.0)
		dummy.rotation.y = PI * 0.5   # side-on so the barrel length/girth shows in profile
		var gun: Node3D = dummy.get_node_or_null("GunMount") as Node3D
		if gun != null:
			var gx: Dictionary = CharacterKit.held_weapon_xform(int(weapons[i]))
			gun.scale = gx["scale"]
			gun.position.z = gx["pos_z"]
		_camera.add_child(dummy)


## Visual QA (--remote-vault-test): upright dummy next to one frozen in the mantle/clamber pose (a
## deep forward lean over an obstacle) — the same forward pose a remote holds while auto-vaulting.
func _ensure_vaultpose_demo(now: float) -> void:
	if not vaultpose_demo or _vaultpose_demo_done or _camera == null or now < 1.0:
		return
	_vaultpose_demo_done = true
	var upright := CharacterKit.build()
	upright.position = Vector3(-0.8, -1.1, -3.0)
	_camera.add_child(upright)
	var mantling := CharacterKit.build()
	mantling.transform.basis = Basis.IDENTITY.rotated(Vector3(1, 0, 0), VAULT_PITCH)   # deep forward clamber
	mantling.position = Vector3(0.8, -1.1, -3.0)
	_camera.add_child(mantling)


## Visual QA (--remote-melee-test): upright dummy next to one frozen at the peak melee lunge (a deep
## forward strike) — the peak of the procedural swing arc.
func _ensure_meleepose_demo(now: float) -> void:
	if not meleepose_demo or _meleepose_demo_done or _camera == null or now < 1.0:
		return
	_meleepose_demo_done = true
	var upright := CharacterKit.build()
	upright.position = Vector3(-0.8, -1.1, -3.0)
	_camera.add_child(upright)
	var swinging := CharacterKit.build()
	swinging.transform.basis = Basis.IDENTITY.rotated(Vector3(1, 0, 0), MELEE_SWING_PITCH)   # peak lunge
	swinging.position = Vector3(0.8, -1.1, -3.0)
	_camera.add_child(swinging)


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
	_spawn_footstep_fx(at, 1.0, now, Stance.STAND, FootstepAudio.LAND)
	play_land_dip(1.0)


## Visual QA (--destroy-test): pump piece destruction bursts (debris + dust) in front of the camera
## on a cadence, alternating "destroy" and "damage" feedback so a screenshot catches both.
func _ensure_destroy_demo(now: float) -> void:
	if not destroy_demo or _camera == null or now < _destroy_demo_next:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	_destroy_demo_next = now + 0.5
	var fwd := (-cb.basis.z).normalized()
	var at := cb.origin + fwd * 7.0 + Vector3(0, 0.5, 0)
	_play_piece_destroy_fx(at + cb.basis.x * -2.0, now)
	_play_piece_damage_fx(at + cb.basis.x * 2.0, now)


## Visual QA (--collapse-test): play the whole-building collapse cinematic in front of the camera on a
## slow cadence (dust cloud + heavy debris + screen shake + rubble mound).
func _ensure_collapse_demo(now: float) -> void:
	if not collapse_demo or _camera == null or now < _collapse_demo_next:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	_collapse_demo_next = now + 1.2   # re-fire faster than the ~1.4 s dust life so a single shot catches it
	var fwd := (-cb.basis.z).normalized()
	var at := cb.origin + fwd * 12.0; at.y = 0.0
	_play_collapse_fx(at, now)


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
	_held_weapon.erase(id)
	_step_accum.erase(id)
	_step_prev.erase(id)
	_air_y.erase(id)
	_air_vy.erase(id)
	_air_fell.erase(id)
	_fire_recoil.erase(id)
	_flinch.erase(id)
	_prev_health_r.erase(id)
	_reload_until.erase(id)
	_melee_swing.erase(id)
	_vault_until.erase(id)
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
	var mat := fx_material(ArtPalette.FRIENDLY)
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
	# Hit-flinch: arm a brief forward stagger when this pawn's replicated health dropped since the last
	# snapshot (took damage from anyone). health holds steady between sim ticks, so the drop fires once.
	var ph: int = _prev_health_r.get(id, es.health)
	if es.health < ph and es.alive and not es.is_downed:
		_flinch[id] = _now + FLINCH_TTL
	_prev_health_r[id] = es.health
	# Armor-tier vest/helmet (M5.5-P2). Re-apply only when this (pooled) node's tier changes — a node
	# recycled from the free list may still carry the previous id's tier. Cheap + before any return.
	if _armor_tier.get(id, -1) != es.armor_class:
		ArmorVisual.apply(node, es.armor_class)
		_armor_tier[id] = es.armor_class
	# Per-weapon held-gun silhouette (procedural body only; the GLB path carries its own HeldWeapon).
	# Re-shape the "GunMount" stub when this pooled node's weapon changes, same recycle guard as armor.
	if not use_models and _held_weapon.get(id, -1) != es.weapon:
		var gun: Node3D = node.get_node_or_null("GunMount") as Node3D
		if gun != null:
			var gx: Dictionary = CharacterKit.held_weapon_xform(es.weapon)
			gun.scale = gx["scale"]
			gun.position.z = gx["pos_z"]
		_held_weapon[id] = es.weapon
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
		# Firing (SHOT_FX) -> shoot clip; reloading (RELOAD_FX) -> "interact"; meleeing (MELEE_FX) ->
		# the authored "attack-melee" clip (wins over both — a deliberate strike).
		var firing := _now < float(_fire_recoil.get(id, 0.0))
		var sel: Dictionary = CharacterAnim.clip_for(es.is_downed, speed, es.stance, firing, _is_reloading(id), _is_meleeing(id))
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

	if _seated_ids.has(id):
		# Vehicle occupant: sit the figure onto the seat instead of standing it upright at (and poking
		# through) the hull. Lower + compress to a shorter, slightly reclined silhouette; keep the
		# rider's own yaw so a gunner still faces where they aim. Cross-referenced from VehicleState.seats
		# (SeatPose) — no wire change. Wins over airborne/climb inference (a seat-slaved pos can jitter).
		var sb := Basis.IDENTITY.rotated(Vector3.UP, es.yaw)
		sb = sb.rotated(sb.x, -SeatPose.SIT_RECLINE)   # negative X = recline backward (sitting), not a crouch
		node.position = Vector3(es.pos.x, es.pos.y + SeatPose.SIT_LIFT, es.pos.z)
		node.transform.basis = sb
		node.scale = Vector3(1.0, SeatPose.SIT_HEIGHT_SCALE, 1.0)
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

	if _is_vaulting_pose(id):
		# Auto-vault (VAULT_FX): a deep forward clamber over the obstacle — distinct from the upright
		# airborne jump tuck. Wins over the airborne inference (a vault lifts the pawn, which would
		# otherwise read as a plain jump). Pitch about the feet, keeping the stance height scale.
		var vb := Basis.IDENTITY.rotated(Vector3.UP, es.yaw)
		vb = vb.rotated(vb.x, VAULT_PITCH)
		node.position = Vector3(es.pos.x, es.pos.y, es.pos.z)
		node.transform.basis = vb
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
	# Orientation: yaw around Y, a transient fire-recoil pitch (lean back) about the body's right, then
	# lean tilt as a roll about local Z. Built with rotated() so the recoil is facing-relative; reduces
	# to the old from_euler(0,yaw,tilt) when recoil=0. Set basis BEFORE scale (scale preserves rotation).
	var fb := Basis.IDENTITY.rotated(Vector3.UP, es.yaw)
	# Body-pitch recoil twitch for the procedural body only — the GLB path uses the authored
	# holding-both-shoot clip instead (applying both would double the recoil).
	# Body-pitch overlay for the procedural body (the GLB path uses authored clips instead). Priority:
	# a melee swing lunge wins (deliberate strike), then the reload forward lean, then the fire kick —
	# the server never lets firing co-occur with reloading, and a swing is brief.
	var recoil := 0.0
	if not use_models:
		if _is_meleeing(id):
			recoil = _melee_pitch(id)
		elif _is_reloading(id):
			recoil = _reload_pitch(id)
		else:
			recoil = _fire_recoil_pitch(id)
	if recoil != 0.0:
		fb = fb.rotated(fb.x, recoil)
	# Hit-flinch composes on top of any recoil/reload/melee lean (you can be shot mid-anything).
	if not use_models:
		var flinch := _flinch_pitch(id)
		if flinch != 0.0:
			fb = fb.rotated(fb.x, flinch)
	if tilt != 0.0:
		fb = fb.rotated(fb.z, tilt)
	node.transform.basis = fb
	# Scale vertically to the stance body-height (crouch reads as a shorter, still-upright figure).
	node.scale = Vector3(1.0, height / CharacterKit.STAND_HEIGHT, 1.0)


# =============================================================================
#  Structure pool helpers (StructureKit pieces; rebuilt when piece/bucket changes)
# =============================================================================

func _sync_structure_pool(world_view: WorldView, now: float) -> void:
	# M11-P4: drain per-piece destruction cosmetics — a removed piece bursts brick debris + dust,
	# a freshly-carved piece kicks a small dust puff (the batched renderer can't see per-piece changes).
	for ev_v: Variant in world_view.take_struct_fx():
		var ev: Dictionary = ev_v
		var p := _structure_xform({"cell": ev["cell"], "yaw": int(ev.get("yaw", 0))}).origin
		p.y += BuildGrid.CELL_SIZE * 0.5   # raise to roughly the piece mid-height
		var col := _wall_debris_color(int(ev.get("type", 0)))   # bricks inherit the wall's material colour
		if String(ev["kind"]) == "destroy":
			_play_piece_destroy_fx(p, now, col)
		else:
			_play_piece_damage_fx(p, now, col)

	# M11: drain collapse events — each fully-collapsed building plays a cinematic + swaps to rubble.
	# Must run every frame (the queue is normally empty; a collapse also bumps the version below).
	for bid_v: Variant in world_view.take_collapsed():
		_spawn_rubble_for(int(bid_v))
		_free_ladders_for(int(bid_v))   # H1: remove the collapsed building's roof ladder render nodes

	# Structures are static once placed — only walk the (large) pool when the store actually changed
	# (build/destroy/damage/collapse). The steady state is a no-op, which is what makes a 77-building
	# map render at full rate instead of re-posing thousands of static pieces every frame.
	var ver: int = world_view.structs_version()
	if ver == _struct_synced_ver:
		return
	_struct_synced_ver = ver
	var dirty: Dictionary = world_view.take_struct_dirty()
	if bool(dirty["all"]) or _struct_groups.is_empty():
		_rebuild_structure_batches(world_view.structures())
	else:
		_incremental_struct_update(dirty["ids"], world_view.structures())


## Batched structure render (perf): all pieces sharing a visual key (piece_id + damage bucket + skirt)
## are IDENTICAL geometry, so they draw as one MultiMesh instead of one node per piece. Collapses the
## town's ~8k pieces / ~16k draw calls to a few hundred. Rebuilt only on a structure-version change
## (build/destroy/damage/collapse) — static the rest of the time. Per-piece build/destroy pops are
## dropped (cosmetic); destruction still reflects instantly on the next rebuild.
func _rebuild_structure_batches(structs: Dictionary) -> void:
	for key: String in _struct_groups:
		for n: Node3D in _struct_groups[key]["mmis"]:
			n.queue_free()
	_struct_groups.clear()
	_struct_key_of.clear()
	# NB: _building_footprint is NOT cleared here — it persists + only grows, so a collapse still knows
	# the original footprint after damage has removed the ground pieces.

	# M12-P2: under-construction build sites are NOT batched — each renders as an individual ghost
	# (translucent target silhouette + a progress fill). Split them out before grouping the rest.
	var under: Dictionary = {}
	for id_v: Variant in structs:
		if int((structs[id_v] as Dictionary).get("under_construction", 0)) == 1:
			under[id_v] = structs[id_v]
	_sync_buildsite_ghosts(under)

	# Per-building cell-footprint bounds from RAW cells (before any _structure_xform call, which now
	# depends on these — computing from cells avoids the circular reference).
	_building_bounds.clear()
	for id_v: Variant in structs:
		var r: Dictionary = structs[id_v]
		var rbid := int(r.get("building_id", 0))
		if rbid == 0:
			continue
		var rc: Vector3i = r["cell"] as Vector3i
		if not _building_bounds.has(rbid):
			_building_bounds[rbid] = {"cxmin": rc.x, "cxmax": rc.x, "czmin": rc.z, "czmax": rc.z}
		else:
			var bb: Dictionary = _building_bounds[rbid]
			bb["cxmin"] = mini(int(bb["cxmin"]), rc.x); bb["cxmax"] = maxi(int(bb["cxmax"]), rc.x)
			bb["czmin"] = mini(int(bb["czmin"]), rc.z); bb["czmax"] = maxi(int(bb["czmax"]), rc.z)

	# Group piece ids by visual key; union each building's extents into its persistent footprint.
	for id_v: Variant in structs:
		var rec: Dictionary = structs[id_v]
		if int(rec.get("under_construction", 0)) == 1:
			continue   # rendered as a ghost above
		var key: String = _struct_visual_key(rec)
		if not _struct_groups.has(key):
			_struct_groups[key] = {"ids": {}, "mmis": []}
		(_struct_groups[key]["ids"] as Dictionary)[int(id_v)] = true
		_struct_key_of[int(id_v)] = key
		var bid: int = int(rec.get("building_id", 0))
		if bid != 0:
			_union_building_footprint(bid, _structure_xform(rec).origin)

	for key: String in _struct_groups:
		_build_key_mmis(key, structs)


## (Re)build the MultiMeshInstances of one visual-key group from its current member ids.
## One MultiMeshInstance3D per (visual key, mesh slot of the piece's kit node).
func _build_group_mmis(key: String, structs: Dictionary) -> void:
	var g: Dictionary = _struct_groups[key]
	for n: Node3D in g["mmis"]:
		n.queue_free()
	g["mmis"] = []
	var ids: Dictionary = g["ids"]
	if ids.is_empty():
		_struct_groups.erase(key)
		return
	var xforms: Array = []
	var sample: Dictionary = {}
	for id_v: Variant in ids:
		var rec: Dictionary = structs[id_v]
		if sample.is_empty():
			sample = rec
		xforms.append(_structure_xform(rec))
	var template: Node3D = _make_structure_node(sample)
	var slots: Array = []
	_collect_mesh_slots(template, Transform3D.IDENTITY, slots)
	template.queue_free()   # template was never added to the tree
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
		(g["mmis"] as Array).append(mmi)


## Dispatch a visual-key group to its builder: "P:<type>" keys are partially-carved pieces rendered
## as a per-chunk hole grid; everything else is the batched whole-mesh path.
func _build_key_mmis(key: String, structs: Dictionary) -> void:
	if key.begins_with("P:"):
		_build_promoted_mmis(key, structs)
	else:
		_build_group_mmis(key, structs)


## M11 Gate-B — HOLE-AWARE GEOMETRY. A partially-carved chunked piece (0 < alive < full) can't show a
## sub-cell hole inside the batched whole-mesh (a MultiMesh draws N copies of ONE mesh). So we PROMOTE
## it: drop the whole kit mesh and instead draw only its ALIVE 0.25 m chunks as a grid of little boxes,
## leaving a real see-through gap where chunks were cleared. All promoted pieces of one type still batch
## into a SINGLE MultiMesh of a unit cube (per-instance scale) so the cost is O(alive chunks in damaged
## pieces) and paid only on the event-driven structure-version change — pristine pieces never promote.
func _is_promotable(rec: Dictionary) -> bool:
	if int(rec.get("under_construction", 0)) == 1:
		return false
	var type_idx := int(rec.get("type", 0))
	# Sub-cell holes are ONLY for vertical walls: the chunk grid is a vertical face (U = width, V = up).
	# A horizontal piece (floor/roof) or a non-wall piece (stairs/railings/columns/props) promoted with
	# that geometry would stand the grid UP as a vertical block poking through the deck (playtest R1) —
	# so those keep the batched whole-mesh until fully removed.
	if not _is_wall_piece(type_idx):
		return false
	var grid := _grid_of(type_idx)
	if grid < 2:
		return false   # 1x1 pieces are alive-or-gone; no sub-cell hole
	var full := ChunkMask.full_mask(grid)
	var mask := int(rec.get("chunks", -1)) & full
	return mask != full and mask != 0   # partially carved


## Vertical wall pieces that get sub-cell holes: the building wall family + player-built fortifications.
func _is_wall_piece(type_idx: int) -> bool:
	var pid: String = STRUCT_TYPE_ID[type_idx] if type_idx < STRUCT_TYPE_ID.size() else ""
	return pid.begins_with("bwall") or pid == "wall" or pid == "sandbag"


func _build_promoted_mmis(key: String, structs: Dictionary) -> void:
	var g: Dictionary = _struct_groups[key]
	for n: Node3D in g["mmis"]:
		n.queue_free()
	g["mmis"] = []
	var ids: Dictionary = g["ids"]
	if ids.is_empty():
		_struct_groups.erase(key)
		return
	var type_idx := int(key.substr(2))   # "P:<type>"
	var grid := _grid_of(type_idx)
	var height := _promoted_height(type_idx)
	var thickness := _promoted_thickness(type_idx)
	var xforms: Array = []
	for id_v: Variant in ids:
		var rec: Dictionary = structs[id_v]
		var piece_xform := _structure_xform(rec)
		for local: Transform3D in WorldRenderer.chunk_hole_xforms(int(rec.get("chunks", -1)), grid, height, thickness):
			xforms.append(piece_xform * local)
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _unit_cube_mesh()
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i] as Transform3D)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _promoted_material(type_idx)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mmi)
	(g["mmis"] as Array).append(mmi)


## Local-frame (pre-piece-xform) transforms — one per ALIVE chunk — that subdivide a piece's CELL-wide
## face into a grid*grid array of sub-cell boxes, omitting cleared chunks. The local frame matches
## _structure_xform (origin at cell centre x/z + cell base y; +X = U/width, +Y = up; z = 0 at the wall
## centre-plane). Mirrors ChunkMask's bit layout (bit = row*grid+col, bit 0 = min-U/min-V corner) so a
## rendered hole lands exactly where the sim cleared chunks. Pure -> unit-testable.
static func chunk_hole_xforms(mask: int, grid: int, height: float, thickness: float) -> Array:
	var out: Array = []
	if grid <= 0:
		return out
	var ustep := BuildGrid.CELL_SIZE / float(grid)
	var vstep := height / float(grid)
	var x0 := -BuildGrid.CELL_SIZE * 0.5
	var scale := Basis.from_scale(Vector3(ustep, vstep, thickness))
	for row in grid:
		for col in grid:
			if (mask & (1 << (row * grid + col))) == 0:
				continue
			var pos := Vector3(x0 + (float(col) + 0.5) * ustep, (float(row) + 0.5) * vstep, 0.0)
			out.append(Transform3D(scale, pos))
	return out


func _promoted_height(type_idx: int) -> float:
	var half := false
	if piece_catalog != null:
		half = piece_catalog.is_half(type_idx)
	elif type_idx < STRUCT_TYPE_ID.size():
		half = STRUCT_TYPE_ID[type_idx] == "bwall_half"
	return BuildGrid.CELL_SIZE * (0.5 if half else 1.0)


## Wall depth for the chunk boxes (perp to the face). A representative slab thickness — the exact kit
## depth varies (0.3–0.35) but a damaged wall reads as broken concrete either way.
func _promoted_thickness(_type_idx: int) -> float:
	return 0.3


func _unit_cube_mesh() -> BoxMesh:
	if _promoted_cube == null:
		_promoted_cube = BoxMesh.new()
		_promoted_cube.size = Vector3.ONE
	return _promoted_cube


func _promoted_material(type_idx: int) -> StandardMaterial3D:
	if _promoted_mats.has(type_idx):
		return _promoted_mats[type_idx]
	var pid: String = STRUCT_TYPE_ID[type_idx] if type_idx < STRUCT_TYPE_ID.size() else "bwall"
	var base: Color = BuildingKit.COL_WALL
	var tex := "concrete"
	if pid.contains("brick"):
		base = BuildingKit.COL_BRICK; tex = "brick"
	elif pid.contains("metal"):
		base = BuildingKit.COL_METALW; tex = "metal"
	elif pid.contains("wood"):
		base = BuildingKit.COL_WOODW; tex = "wood"
	var mat := StandardMaterial3D.new()
	# Match the intact wall EXACTLY — same base colour + texture, and the same world-space triplanar
	# mapping so the per-chunk hole geometry samples the identical concrete as the wall around it (no
	# dark tint, no flat/lighter rectangle around the gap — playtest). The hole is the damage indicator.
	mat.albedo_color = base
	mat.roughness = 0.9
	mat.albedo_texture = BuildingTextures.tex(tex)
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3.ONE * BuildingKit.TEX_WORLD_SCALE
	_promoted_mats[type_idx] = mat
	return mat


## Incremental path: a structure delta touched only `dirty_ids` — move each between its old and
## new visual-key groups and rebuild ONLY the groups whose membership changed. Untouched groups
## keep their MultiMesh nodes (the whole point: no full 8k-piece regroup per chunk carve).
func _incremental_struct_update(dirty_ids: Array, structs: Dictionary) -> void:
	var dirty_keys: Dictionary = {}
	for id_v: Variant in dirty_ids:
		var id := int(id_v)
		var old_key: String = _struct_key_of.get(id, "")
		var rec: Variant = structs.get(id)
		var new_key := ""
		if rec != null and int((rec as Dictionary).get("under_construction", 0)) != 1:
			new_key = _struct_visual_key(rec)
		if new_key == old_key:
			# A promoted (partially-carved) piece keeps its "P:type" key as more chunks clear, but its
			# hole mask changed -> the group MUST rebuild. Normal batches never change transforms in place.
			if new_key.begins_with("P:"):
				dirty_keys[new_key] = true
			continue
		if old_key != "" and _struct_groups.has(old_key):
			(_struct_groups[old_key]["ids"] as Dictionary).erase(id)
			dirty_keys[old_key] = true
		if new_key != "":
			if not _struct_groups.has(new_key):
				_struct_groups[new_key] = {"ids": {}, "mmis": []}
			(_struct_groups[new_key]["ids"] as Dictionary)[id] = true
			dirty_keys[new_key] = true
			_struct_key_of[id] = new_key
			var bid: int = int((rec as Dictionary).get("building_id", 0))
			if bid != 0:
				_union_building_footprint(bid, _structure_xform(rec).origin)
		else:
			_struct_key_of.erase(id)
	for key: String in dirty_keys:
		if _struct_groups.has(key):
			_build_key_mmis(key, structs)
	# Ghost reconcile stays a full pass — under-construction sites are few, and OP_PROGRESS
	# (same-key above) still needs its fill re-aimed.
	var under: Dictionary = {}
	for id_v: Variant in structs:
		if int((structs[id_v] as Dictionary).get("under_construction", 0)) == 1:
			under[id_v] = structs[id_v]
	_sync_buildsite_ghosts(under)


## M12-P2: reconcile the per-id build-site ghosts against the current under-construction set. A site
## leaves this set when it completes (the server resends it as a finished piece — the batch path takes
## over) or is removed/decayed, so anything no longer present is freed. New sites build a ghost; known
## ones just re-aim their fill to the latest progress fraction.
func _sync_buildsite_ghosts(under: Dictionary) -> void:
	var drop: Array = []
	for id_v: Variant in _buildsite_nodes:
		if not under.has(id_v):
			drop.append(id_v)
	for id_v: Variant in drop:
		(_buildsite_nodes[id_v]["root"] as Node3D).queue_free()
		_buildsite_nodes.erase(id_v)
	for id_v: Variant in under:
		var rec: Dictionary = under[id_v]
		if not _buildsite_nodes.has(id_v):
			_buildsite_nodes[id_v] = _build_buildsite_ghost(rec)
			(_buildsite_nodes[id_v]["root"] as Node3D).transform = _structure_xform(rec)
		_set_buildsite_fraction(_buildsite_nodes[id_v], _buildsite_fraction(rec))


## Shovel-progress fraction (0..1) for a build site, derived from build_progress vs the piece's
## catalog build_cost (the wire ships only progress). Clamped to a visible minimum so a just-placed
## site still shows a footing slab.
func _buildsite_fraction(rec: Dictionary) -> float:
	var cost := 60
	if piece_catalog != null:
		cost = piece_catalog.build_cost_of(int(rec.get("type", 0)))
	var frac := float(int(rec.get("build_progress", 0))) / float(maxi(cost, 1))
	return clampf(frac, 0.04, 1.0)


## Build the node for a build site: the real target-piece geometry skinned in an amber "scaffold"
## material, vertically scaled so the structure RISES from the ground as shovel progress accrues
## (BattleBit-style). No overlapping translucent layers (those wash out), so the silhouette stays
## crisp. Returns the bookkeeping dict stored in _buildsite_nodes.
func _build_buildsite_ghost(rec: Dictionary) -> Dictionary:
	var root := Node3D.new()
	var geom := _make_structure_node(rec)
	_skin_meshes(geom, _buildsite_material())
	root.add_child(geom)
	add_child(root)
	return {"root": root, "geom": geom, "last_frac": -1.0}


## M12 build-placement: a single pooled "hologram" of the piece the player is about to build,
## re-posed to the aimed cell each frame and tinted green (valid) / red (invalid). Hidden when the
## build tool is not active. Geometry is rebuilt only when the selected piece/bucket changes.
func set_build_preview(active: bool, piece_id: String, cell: Vector3i, yaw_step: int, valid: bool) -> void:
	if not active:
		if _build_preview != null:
			_build_preview.visible = false
		return
	if _build_preview == null or piece_id != _build_preview_key:
		if _build_preview != null:
			_build_preview.visible = false   # queue_free is deferred — hide now so it doesn't double-render this frame
			_build_preview.queue_free()
		_build_preview = StructureKit.build(piece_id, 3)   # always pristine bucket for the ghost
		_build_preview_mat = StandardMaterial3D.new()
		_build_preview_mat.emission_enabled = true
		_skin_meshes(_build_preview, _build_preview_mat)
		add_child(_build_preview)
		_build_preview_key = piece_id
	_build_preview.visible = true
	_build_preview.transform = _structure_xform({"cell": cell, "yaw": yaw_step})
	var col := BUILD_OK_COLOR if valid else BUILD_BAD_COLOR
	_build_preview_mat.albedo_color = col
	_build_preview_mat.emission = col


## Re-aim a build site to a progress fraction: vertically scale the target geometry from the ground so
## it grows as it is shovelled in. Piece geometry sits with its base at y==0, so a plain Y-scale about
## the root grows it upward from the footing.
func _set_buildsite_fraction(entry: Dictionary, frac: float) -> void:
	if absf(frac - float(entry["last_frac"])) < 0.005:
		return
	entry["last_frac"] = frac
	(entry["geom"] as Node3D).scale = Vector3(1.0, maxf(frac, 0.04), 1.0)


## Amber, lightly-translucent "under construction" scaffold material (single layer per face — no
## overlapping translucent silhouette, so it reads crisply and never washes the screen).
func _buildsite_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = BUILDSITE_FILL_COLOR
	m.emission_enabled = true
	m.emission = BUILDSITE_FILL_COLOR
	m.emission_energy_multiplier = 0.35
	return m


## Override every MeshInstance3D under a node with one shared material (used to skin a piece template).
func _skin_meshes(node: Node3D, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		if child is Node3D:
			_skin_meshes(child as Node3D, mat)


## Visual key: pieces with the same id + damage bucket + skirt are byte-identical geometry, so they
## share a MultiMesh. (Skirt depends on cell.y==0, so two same-type pieces at different floors differ.)
func _struct_visual_key(rec: Dictionary) -> String:
	var type_idx: int = int(rec.get("type", 0))
	var cell: Vector3i = rec["cell"] as Vector3i
	var piece_id: String = STRUCT_TYPE_ID[type_idx] if type_idx < STRUCT_TYPE_ID.size() else "wall"
	# M11 Gate-B: a partially-carved chunked piece is PROMOTED out of the batched whole-mesh into a
	# per-chunk hole grid (its own MultiMesh) so a real see-through hole shows exactly where you shot.
	# Pristine (full mask) and fully-removed pieces stay on the cheap batched path -> no steady-state cost.
	if _is_promotable(rec):
		return "P:%d" % type_idx
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
	# Edge-align building walls: shift OUT from the building centre to the footprint edge (matches the
	# preview). Direction is from the cell vs the building centre (yaw can't tell N from S / E from W).
	# Applied to the piece transform, so the pristine batched mesh AND the promoted hole chunks (which
	# both derive from this) move together and stay aligned. Corner/floor/column/props excepted.
	var type_idx := int(rec.get("type", 0))
	var ys := int(rec.get("yaw", 0))
	var bid := int(rec.get("building_id", 0))
	if bid != 0 and _building_bounds.has(bid):
		var pid: String = STRUCT_TYPE_ID[type_idx] if type_idx < STRUCT_TYPE_ID.size() else ""
		if pid.begins_with("bwall") and pid != "bwall_corner":
			var b: Dictionary = _building_bounds[bid]
			var out_amt := BuildGrid.CELL_SIZE * 0.5 - 0.15
			if ys % 4 == 0:   # yaw 0/4 -> thin in Z -> push along Z
				pos.z += signf(float(cell.z) - float(int(b["czmin"]) + int(b["czmax"])) * 0.5) * out_amt
			else:             # yaw 2/6 -> thin in X -> push along X
				pos.x += signf(float(cell.x) - float(int(b["cxmin"]) + int(b["cxmax"])) * 0.5) * out_amt
	var basis := Basis.from_euler(Vector3(0.0, BuildGrid.yaw_radians(ys), 0.0))
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
	# bwall_corner bakes orientation into its L mesh via BuildingKit — don't rotate again.
	var type_idx: int = int(rec.get("type", 0))
	var pid: String = STRUCT_TYPE_ID[type_idx] if type_idx < STRUCT_TYPE_ID.size() else "wall"
	var yaw_rad := 0.0 if pid == "bwall_corner" else BuildGrid.yaw_radians(int(rec.get("yaw", 0)))
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
	var cam_pos: Vector3 = eye if eye.is_finite() else pawn.eye_position()
	# Rotation uses the client-authoritative LOOK (input) yaw/pitch, not the server-reconciled
	# pawn yaw. That lets the wire carry a flipped aim yaw (yaw+PI, to match Combat._forward to
	# where the camera points) without the reconciled value rotating the view 180°.
	var basis := Basis.from_euler(Vector3(look_pitch, look_yaw, 0.0))
	# Lean (Q/E): peek the eye sideways + roll the view so leaning is visible to the local player,
	# not just to remotes/the server. The lateral shift matches the server's LEAN_OFFSET shot origin.
	var cl := StancePose.camera_lean(pawn.lean)
	if cl["lat"] != 0.0:
		cam_pos += basis.x * float(cl["lat"])
		basis = basis.rotated(basis.z.normalized(), float(cl["roll"]))
	_camera.position = cam_pos
	_camera.transform.basis = basis
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
		return BuildingKit.build(piece_id, _bucket_of(rec), skirt, int(rec.get("yaw", 0)))
	return StructureKit.build(piece_id, _bucket_of(rec))


## M11: replace a collapsed building with a rubble mound at its last-known centroid + a collapse
## cinematic (rolling dust, flung debris, screen shake) so a building coming down reads as an event.
## Grow building `bid`'s cached footprint to include a piece origin at `o` (cell-centre). Union-only —
## the box never shrinks, so after damage strips the ground pieces the original ground centre survives.
func _union_building_footprint(bid: int, o: Vector3) -> void:
	var half := BuildGrid.CELL_SIZE * 0.5
	if not _building_footprint.has(bid):
		_building_footprint[bid] = {"min": Vector3(o.x - half, o.y, o.z - half), "max": Vector3(o.x + half, o.y, o.z + half)}
		return
	var b: Dictionary = _building_footprint[bid]
	var mn: Vector3 = b["min"]
	var mx: Vector3 = b["max"]
	b["min"] = Vector3(minf(mn.x, o.x - half), minf(mn.y, o.y), minf(mn.z, o.z - half))
	b["max"] = Vector3(maxf(mx.x, o.x + half), maxf(mx.y, o.y), maxf(mx.z, o.z + half))
	_building_footprint[bid] = b

func _spawn_rubble_for(building_id: int) -> void:
	if _building_footprint.has(building_id):
		# Live collapse we witnessed the pieces of: full cinematic (fireball/debris/shake) + the mound,
		# anchored on the footprint's GROUND centre (min.y) so the mound lands on the ground.
		var b: Dictionary = _building_footprint[building_id]
		var mn: Vector3 = b["min"]
		var mx: Vector3 = b["max"]
		var center := Vector3((mn.x + mx.x) * 0.5, mn.y, (mn.z + mx.z) * 0.5)
		_building_footprint.erase(building_id)
		_play_collapse_fx(center, _now, mn, mx)
	# Late joiner (else): a building that fell before we connected is already REAL `brubble` pieces in
	# our structure baseline (R5) — nothing cosmetic to place, and no explosion cinematic (which would
	# "blow up" every past collapse in the first second after connecting).

## Ground anchor for a building we hold no live geometry for (rejoin rubble). Prefer the building's own
## roof-ladder ring — its XZ centroid tracks the footprint and the nodes are still present here (freed
## right after us) — and fall back to the static MapDef footprint cell for ladderless buildings.
func _footprint_anchor(building_id: int) -> Vector3:
	if _ladder_nodes.has(building_id) and not (_ladder_nodes[building_id] as Array).is_empty():
		var nodes: Array = _ladder_nodes[building_id]
		var sum := Vector3.ZERO
		for ln: Node3D in nodes:
			sum += ln.position
		var c: Vector3 = sum / float(nodes.size())
		return Vector3(c.x, STRUCT_LIFT, c.z)
	if _map != null:
		var idx := building_id - 1   # building_id = building index + 1 (MapDef convention)
		if idx >= 0 and idx < _map.buildings.size():
			var cell: Vector3i = (_map.buildings[idx] as Dictionary).get("origin_cell", Vector3i.ZERO)
			var half := BuildGrid.CELL_SIZE * 0.5
			return Vector3(float(cell.x) * BuildGrid.CELL_SIZE + half, STRUCT_LIFT, float(cell.z) * BuildGrid.CELL_SIZE + half)
	return Vector3.INF


# =============================================================================
#  M11-P4 destruction cosmetics — piece debris/dust + collapse cinematic + shake
# =============================================================================
const BRICK_DEBRIS_TTL := 5.0   # debris tumbles, lands, and rests on the ground a while before fading out (playtest)
const COL_DEBRIS_A := Color(0.55, 0.53, 0.49)   # broken concrete (light) — matches BuildingKit rubble
const COL_DEBRIS_B := Color(0.47, 0.45, 0.42)   # broken concrete (mid)
const COL_DEBRIS_BRICK := Color(0.58, 0.31, 0.25)   # brick-red shard
const DUST_COLOR := Color(0.66, 0.63, 0.57, 0.6)    # warm concrete dust

## A piece reached 0 chunks: a concrete dust puff + a big fan of debris in the wall's material colour.
func _play_piece_destroy_fx(pos: Vector3, now: float, col: Color = COL_DEBRIS_A) -> void:
	_fx.spawn_puff(pos, 1.6, 0.55, now, DUST_COLOR)
	_spawn_brick_debris(pos, now, 14, 0.20, 4.5, 6.0, col)

## A piece took chunk damage but still stands (e.g. an RPG breach): a dust kick + a shower of the bricks
## that were knocked out of the wall (in the wall's colour) — they fly off, tumble, and settle (playtest).
func _play_piece_damage_fx(pos: Vector3, now: float, col: Color = COL_DEBRIS_A) -> void:
	_fx.spawn_puff(pos, 0.8, 0.4, now, DUST_COLOR)
	_spawn_brick_debris(pos, now, 9, 0.16, 3.2, 4.2, col)

## Debris colour for a wall type — grey concrete walls throw grey rubble, brick throws red brick, etc.
## (playtest: bricks were always red). Mirrors the wall-material colour choice in _promoted_material.
func _wall_debris_color(type_idx: int) -> Color:
	var pid: String = STRUCT_TYPE_ID[type_idx] if type_idx < STRUCT_TYPE_ID.size() else "bwall"
	if pid.contains("brick"):
		return COL_DEBRIS_BRICK
	if pid.contains("metal"):
		return BuildingKit.COL_METALW
	if pid.contains("wood"):
		return BuildingKit.COL_WOODW
	return COL_DEBRIS_A   # broken grey concrete — matches the (grey) concrete walls

## Brick/concrete chunks flung from a damage point, integrated + settled by the shared FxPool debris pool.
## `box` = cube edge (m), `spread`/`lift` = horizontal/vertical launch speed.
func _spawn_brick_debris(pos: Vector3, now: float, count: int, box: float, spread: float, lift: float, base_col: Color = COL_DEBRIS_A) -> void:
	if count <= 0:
		return
	# Shades of the destroyed wall's material colour (light/mid/base) so the flung bricks match it.
	var cols := [base_col, base_col.darkened(0.14), base_col.lightened(0.10)]
	for i in range(count):
		var node := MeshInstance3D.new()
		# Vary the shard size per index (no per-frame RNG) so debris doesn't read as uniform cubes.
		var s := box * (0.7 + 0.6 * float(i % 3))
		var bmesh := BoxMesh.new(); bmesh.size = Vector3(s, s * 0.8, s)
		node.mesh = bmesh
		node.position = pos
		var mat := StandardMaterial3D.new()
		mat.albedo_color = cols[i % cols.size()]
		mat.roughness = 0.95
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		var ang := TAU * float(i) / float(count) + float(i) * 0.7
		var rad := spread * (0.5 + 0.5 * float((i + 1) % 3))
		var vel := Vector3(cos(ang) * rad, lift + float(i % 3) * 1.2, sin(ang) * rad)
		# Deterministic per-shard tumble (rad/s) so each brick spins as it flies (no per-frame RNG).
		var spin := Vector3(3.0 + 2.0 * float(i % 4), 2.0 + 3.0 * float(i % 3), 5.0 - 1.5 * float(i % 5))
		_fx.push_debris(node, vel, now + BRICK_DEBRIS_TTL, spin)

## Whole-building collapse cinematic: a rolling ground dust cloud, a heavy debris burst, a screen
## shake if the player is close, then the persistent rubble mound. Public-ish so the QA demo reuses it.
func _play_collapse_fx(center: Vector3, now: float, mn: Vector3 = Vector3.INF, mx: Vector3 = Vector3.INF) -> void:
	# Scale the whole cinematic to the building's real footprint (was fixed ~3 m regardless of size, so
	# a 2-storey block left the same pebble puff as a shed). Defaults (no extents) keep the QA demo sane.
	var half_x := 1.5
	var half_z := 1.5
	var height := 4.0
	if mn.is_finite() and mx.is_finite():
		half_x = maxf(1.0, (mx.x - mn.x) * 0.5)
		half_z = maxf(1.0, (mx.z - mn.z) * 0.5)
		height = maxf(2.0, mx.y - mn.y)
	var span := maxf(half_x, half_z)
	# Ground-hugging dust cloud — offset puffs ringed at the footprint edge read as one rolling billow.
	# Long TTL (~3 s) so the collapse lingers as an event, not a 1 s puff (playtest R6).
	for i in range(8):
		var ang := TAU * float(i) / 8.0
		var off := Vector3(cos(ang) * span, 0.4 + 0.4 * float(i % 3), sin(ang) * span)
		_fx.spawn_puff(center + off, span * 2.4, 2.8, now, DUST_COLOR)
	_fx.spawn_puff(center + Vector3(0, 1.2, 0), span * 3.2, 3.2, now, DUST_COLOR)
	_fx.spawn_puff(center + Vector3(0, height * 0.5, 0), span * 2.6, 3.0, now, DUST_COLOR)   # a high billow rolling off the top
	# Heavy debris burst flung up + out; more shards for a bigger footprint (bounded).
	var shards := 22 + clampi(int(half_x * half_z * 0.8), 0, 40)
	_spawn_brick_debris(center + Vector3(0, height * 0.4, 0), now, shards, 0.26, span + 4.0, 8.0)
	# R5: the persistent remnant is now REAL walkable `brubble` pieces (server-stamped, arriving via
	# OP_PLACE), not a cosmetic mound — so this plays only the dust/debris cinematic.
	# Strong, longer shake as the building comes down (the warning rumble preceded this).
	_add_shake(center, now, 0.34, 1.2)

## The persistent rubble a collapsed building leaves behind — a field of mounds tiled across the
## footprint (center = ground centre) so a big building leaves a big, footprint-shaped pile that humps
## higher in the middle and scales taller with building height. A single-cell building collapses to one
## centred mound (nx=nz=1), matching the old behaviour. Deterministic (index-based scatter, no RNG).
func _place_rubble_field(center: Vector3, half_x: float, half_z: float, height: float) -> void:
	var step := 2.2
	var nx := clampi(int(round(half_x * 2.0 / step)), 1, 8)   # cap 8x8 mounds — perf/cosmetic bound
	var nz := clampi(int(round(half_z * 2.0 / step)), 1, 8)
	var h_scale := clampf(height / 6.0, 0.7, 2.2)             # ~3 storeys reads as a tall pile
	var idx := 0
	for ix in range(nx):
		for iz in range(nz):
			var fx := ((float(ix) + 0.5) / float(nx)) * 2.0 - 1.0   # -1..1 across the footprint
			var fz := ((float(iz) + 0.5) / float(nz)) * 2.0 - 1.0
			var radial := 1.0 - 0.4 * minf(1.0, sqrt(fx * fx + fz * fz))
			var jit := 0.4 * sin(float(idx) * 12.9898)
			var m := BuildingKit.build_rubble()
			m.position = center + Vector3(fx * half_x + jit, 0.0, fz * half_z - jit)
			m.rotation.y = float(idx) * 0.7
			m.scale = Vector3(1.0, clampf(radial * h_scale, 0.5, 2.4), 1.0)
			add_child(m)
			idx += 1

## Back-compat single-mound entry (join-replay path lacks live extents) — a modest 3x3 m rubble field.
func _place_rubble_mound(center: Vector3) -> void:
	_place_rubble_field(center, 1.5, 1.5, 4.0)

## R6 — imminent-collapse rumble. A building sends a COLLAPSE_WARNING ~3 s before it actually falls;
## rumble the view (bursts that RAMP UP toward the fall) for that window, then the collapse cinematic
## adds its big shake. Bounded (collapses are rare); entries clear when their window elapses.
const COLLAPSE_WARN_DURATION := 7.0   # matches server COLLAPSE_WARN_TICKS (210 @ 30 Hz) — time to escape
var _collapse_warnings: Array = []   # [{center, start, end}]

func begin_collapse_warning(center: Vector3, now: float) -> void:
	_collapse_warnings.append({"center": center, "start": now, "end": now + COLLAPSE_WARN_DURATION})

func _apply_collapse_warnings(now: float) -> void:
	if _collapse_warnings.is_empty():
		return
	var kept: Array = []
	for w in _collapse_warnings:
		if now >= float(w["end"]):
			continue
		var t := clampf((now - float(w["start"])) / COLLAPSE_WARN_DURATION, 0.0, 1.0)
		_add_shake(w["center"], now, 0.05 + 0.12 * t, 0.25)   # short bursts, intensity ramps toward the fall
		kept.append(w)
	_collapse_warnings = kept

## Arm a camera shake of `mag` metres for `dur` s if `world_pos` is within feel range of the camera.
func _add_shake(world_pos: Vector3, now: float, mag: float, dur: float) -> void:
	if _camera == null:
		return
	var dist := _camera.global_transform.origin.distance_to(world_pos)
	if dist > SHAKE_RANGE:
		return
	var falloff := 1.0 - dist / SHAKE_RANGE   # closer = stronger
	var m := mag * falloff
	if m <= _shake_mag and now < _shake_until:
		return   # don't let a weaker/farther event stomp a stronger active shake
	_shake_mag = m
	_shake_t0 = now
	_shake_until = now + dur

const SHAKE_RANGE := 45.0   # m: beyond this a collapse/blast doesn't shake the view

## Apply the active camera shake as a transient positional jitter on top of _apply_camera. Deterministic
## (driven by `now`) so it never depends on Math.random; decays linearly to rest over its duration.
func _apply_shake(now: float) -> void:
	if _camera == null or now >= _shake_until or _shake_mag <= 0.0:
		_shake_mag = 0.0
		return
	var life := (_shake_until - _shake_t0)
	var k := 1.0 - (now - _shake_t0) / life if life > 0.0 else 0.0   # 1 -> 0 envelope
	var amp := _shake_mag * maxf(k, 0.0)
	# Two incommensurate frequencies per axis -> a non-repeating wobble without an RNG.
	var ox := sin(now * 53.0) * amp
	var oy := sin(now * 61.0 + 1.3) * amp
	var basis := _camera.global_transform.basis
	_camera.position += basis.x * ox + basis.y * oy


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
	var mat := fx_material(Color(color.r, color.g, color.b, 0.55), true, true, color, 1.3)
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

## Visible RED ladder (owner request): two rails + rungs spanning bottom->top, built in local space
## (rails along local X, stacked up local Y) and rotated by `yaw` so the rungs face out from the wall.
## The map's climb VOLUME is yaw-agnostic; this is presentation only, so a ladder reads as a ladder
## and stands out as the way up.
## H1: free the roof-ladder render nodes belonging to a collapsed building (their climb volume is
## already gone server-side), so a ladder never floats in the air where its building used to be.
func _free_ladders_for(building_id: int) -> void:
	if building_id == 0 or not _ladder_nodes.has(building_id):
		return
	for lnode: Node3D in _ladder_nodes[building_id]:
		if is_instance_valid(lnode):
			lnode.queue_free()
	_ladder_nodes.erase(building_id)

func _make_ladder(ladder: Dictionary) -> Node3D:
	var bottom: Vector3 = ladder["bottom"]
	var top: Vector3 = ladder["top"]
	var height: float = maxf(0.5, top.y - bottom.y)
	var half_w := 0.34
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.86, 0.11, 0.11)
	mat.emission_enabled = true
	mat.emission = Color(0.75, 0.06, 0.06)
	mat.emission_energy_multiplier = 0.7
	var root := Node3D.new()
	root.position = bottom
	root.rotation.y = float(ladder.get("yaw", 0.0))
	for s in [-1.0, 1.0]:
		var rail := MeshInstance3D.new()
		var rm := BoxMesh.new(); rm.size = Vector3(0.09, height, 0.09); rail.mesh = rm
		rail.material_override = mat
		rail.position = Vector3(s * half_w, height * 0.5, 0.0)
		root.add_child(rail)
	var rungs := maxi(2, int(height / 0.34))
	for i in range(1, rungs):
		var rung := MeshInstance3D.new()
		var gm := BoxMesh.new(); gm.size = Vector3(half_w * 2.0, 0.06, 0.07); rung.mesh = gm
		rung.material_override = mat
		rung.position = Vector3(0.0, height * float(i) / float(rungs), 0.0)
		root.add_child(rung)
	return root


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
		# Traverse the turret toward the replicated gunner aim. turret_yaw is world-space and the hull
		# already carries heading, so the turret's LOCAL yaw is the difference. Smoothed like the hull
		# (snapshot rate). Skipped gracefully for vehicle kits that have no "Turret" child.
		var turret: Node3D = node.get_node_or_null("Turret") as Node3D
		if turret != null:
			var local_yaw: float = wrapf(vs.turret_yaw - vs.heading, -PI, PI)
			if is_new or k <= 0.0:
				turret.rotation.y = local_yaw
			else:
				turret.rotation.y = lerp_angle(turret.rotation.y, local_yaw, k)
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
	_fx.spawn_blast(pos + Vector3(0, 1.2, 0), Color(1.0, 0.6, 0.16), 1.6, 7.0, FxPoolRef.BLAST_TTL * 1.6, now)
	_fx.spawn_puff(pos + Vector3(0, 1.4, 0), 4.0, 1.2, now, Color(0.18, 0.17, 0.16, 0.7))
	_fx.spawn_debris(pos + Vector3(0, 0.8, 0), now)

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
	_fx.spawn_puff(node.position + Vector3(0, 1.6, 0), size, 1.6, now, color)


## --turret-test: one intact transport sitting broadside with its turret traversed ~55° off the hull
## axis, so a screenshot shows the turret aiming independently of the body (validates the traverse).
func _ensure_turret_demo(now: float) -> void:
	if not turret_demo or _turret_demo_done or _camera == null or now < 1.0:
		return
	var cb := _camera.global_transform
	if not cb.origin.is_finite():
		return
	_turret_demo_done = true
	var fwd := (-cb.basis.z).normalized()
	var base := cb.origin + fwd * 9.0; base.y = 0.0
	var hull_yaw := atan2(-fwd.x, -fwd.z) + PI * 0.5   # hull broadside so the turret traverse is visible
	var veh := _make_vehicle_mesh()
	add_child(veh)
	veh.position = base
	veh.rotation.y = hull_yaw
	var turret: Node3D = veh.get_node_or_null("Turret") as Node3D
	if turret != null:
		turret.rotation.y = deg_to_rad(55.0)   # local traverse off the hull axis (barrel angles toward camera)
	_vehicle_active[_DMG_DEMO_VID] = veh   # reuse the demo vid slot (camera-placed, not snapshot-driven)


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

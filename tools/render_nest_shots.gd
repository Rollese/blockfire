extends SceneTree
## Standalone screenshot harness for M19 P4 "LMG Nest" art sign-off. Loads conquest_town's REAL
## terrain (for scale/ground context) but does NOT stamp buildings into a StructureStore — the goal
## is a clear eyeball of the nest art, not a full match scene, and set_emplacements() (the only API
## this harness needs) has no dependency on the structure/piece pipeline. Feeds one hand-built
## emplacement dict straight to WorldRenderer.set_emplacements() (the same wire shape
## Protocol.decode_emplacement_list() hands the real client) and drives it through four stages —
## intact/unmanned, manned (turret traversed off its resting facing), damaged (scorched tint), and an
## approximate first-person "manning" view down the barrel. Captures a PNG per stage.
##   godot --path . -s res://tools/render_nest_shots.gd --rendering-driver <opengl3|vulkan>
##   (on a headless host: Xvfb :99 -screen 0 1280x720x24 & DISPLAY=:99 godot --path . -s ...)
## Deterministic (no networking, no bots, no live gunner pawn — see NOTE below). A QA tool, not a
## game path.
##
## NOTE (manned stage simplification): a genuinely posed, crouched gunner requires routing through
## WorldRenderer.update()'s full entity pipeline (WorldView remotes_at/self_state, a Prediction, and
## SeatPose/_nest_occupants cross-referencing — see world_renderer.gd:900-924), which in turn wants a
## live replicated pawn EntityState. That is the live-game path, not a light standalone harness, so
## the "manned" stage here only sets occupant != 0 and traverses the turret — it proves the barrel
## re-aims and the nest is flagged manned, but does NOT render a crouched gunner body.

const MAP_PATH := "res://maps/conquest_town.json"
const NEST_POS := Vector3(10.0, 0.0, 10.0)   # arbitrary open spot; building stamping is skipped (see header)
const FACING_YAW := 0.0                       # nest rests facing +Z (forward = (sin, 0, cos))
const TURRET_OFFSET := deg_to_rad(30.0)       # how far the "manned" stage traverses off FACING_YAW
const GUNNER_PAWN_ID := 999                   # placeholder occupant id (no live pawn rendered — see header)

func _initialize() -> void:
	var scene: PackedScene = load("res://client/client.tscn")
	var world: Node3D = scene.instantiate() as Node3D
	get_root().add_child(world)
	var cam: Camera3D = world.get_node("Camera3D") as Camera3D
	cam.current = true

	var map: MapDef = MapDef.load_file(MAP_PATH)
	if map == null:
		push_error("failed to load map"); quit(1); return
	var grid = Terrain.load_for_map(map, "res://maps", Callable())

	var r := WorldRenderer.new()
	world.add_child(r)
	r.set_terrain(grid)
	r.setup(map, cam)

	# Nodes added during _initialize only become "inside tree" after a frame — settle before touching
	# the camera's global transform (else global_position/look_at error and the shot stays at origin).
	await _settle()

	var nest_y := Terrain.height_at(grid, NEST_POS.x, NEST_POS.z) if grid != null else 0.0
	var pos := Vector3(NEST_POS.x, nest_y, NEST_POS.z)
	var muzzle := pos + Vector3(0, LmgNestKit.MUZZLE_UP, 0)

	var dir := "user://nest_shots"
	DirAccess.make_dir_recursive_absolute(dir)

	# --- Stage 0: intact, unmanned — turret resting at the nest's facing_yaw.
	r.set_emplacements([{
		"id": 1, "pos": pos, "facing_yaw": FACING_YAW, "turret_yaw": FACING_YAW,
		"hp_frac": 1.0, "occupant": 0, "team": 0,
	}])
	_frame_third_person(cam, pos, FACING_YAW)
	await _settle()
	await _capture(cam, dir, "0_intact_unmanned")

	# --- Stage 1: manned — occupant set, turret traversed off the resting facing (see header NOTE:
	# no live gunner body, just the flagged-manned nest + traversed barrel).
	var manned_turret := FACING_YAW + TURRET_OFFSET
	r.set_emplacements([{
		"id": 1, "pos": pos, "facing_yaw": FACING_YAW, "turret_yaw": manned_turret,
		"hp_frac": 1.0, "occupant": GUNNER_PAWN_ID, "team": 0,
	}])
	_frame_third_person(cam, pos, FACING_YAW)
	await _settle()
	await _capture(cam, dir, "1_manned")

	# --- Stage 2: damaged — scorched tint (hp_frac well below 1.0), still manned/traversed.
	r.set_emplacements([{
		"id": 1, "pos": pos, "facing_yaw": FACING_YAW, "turret_yaw": manned_turret,
		"hp_frac": 0.35, "occupant": GUNNER_PAWN_ID, "team": 0,
	}])
	_frame_third_person(cam, pos, FACING_YAW)
	await _settle()
	await _capture(cam, dir, "2_damaged")

	# --- Stage 3: approximate first-person "manning" view — camera just behind/above the muzzle,
	# looking out along the traversed turret aim (a stand-in for the real ADS-at-the-gun camera).
	var aim := Vector3(sin(manned_turret), 0.0, cos(manned_turret))
	cam.global_position = muzzle - aim * 0.3 + Vector3(0, 0.15, 0)
	cam.look_at(muzzle + aim * 10.0, Vector3.UP)
	await _settle()
	await _capture(cam, dir, "3_fp_sight")

	print("done")
	quit(0)


## Third-person 3/4 view: camera pulled back+up from the nest, biased toward the front (facing) side
## so the sandbag berm + mounted gun both read clearly in frame.
func _frame_third_person(cam: Camera3D, pos: Vector3, facing_yaw: float) -> void:
	var fwd := Vector3(sin(facing_yaw), 0.0, cos(facing_yaw))
	cam.global_position = pos + fwd * 3.0 + Vector3(3.0, 2.2, 0.0)
	cam.look_at(pos + Vector3(0, 0.7, 0), Vector3.UP)


func _settle() -> void:
	for i in range(6):
		await process_frame


func _capture(cam: Camera3D, dir: String, name: String) -> void:
	var img := get_root().get_texture().get_image()
	var path := "%s/%s.png" % [dir, name]
	img.save_png(path)
	print("wrote ", ProjectSettings.globalize_path(path))

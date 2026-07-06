extends SceneTree
## Standalone screenshot harness for conquest_town road validation. Instantiates client.tscn
## (Camera3D + DirectionalLight3D + WorldEnvironment), runs the SAME map/terrain path the real
## client uses (MapDef.load_file -> Terrain.load_for_map -> WorldRenderer.set_terrain/setup), then
## captures a set of cameras and writes PNGs to user://. Run:
##   godot --path . -s res://tools/render_town_shots.gd --rendering-driver <opengl3|vulkan>
## Not a game path — a QA tool. Deterministic (no networking, no bots).

const MAP_PATH := "res://maps/conquest_town.json"

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

	# Shot list: name -> [eye pos, look-at target]. Heights are eye-level (~1.7 m) added to the flat
	# plateau (H0=0) so the shots frame the ROAD SURFACE the way a standing player sees it.
	var shots := [
		# Standing on the Main Avenue looking N up the spine (the road the owner walks).
		["ave_north", Vector3(0, 1.7, 40), Vector3(0, 1.4, -120)],
		# Standing at the central square looking W down Center-0 cross street toward the hills.
		["cross_west", Vector3(-20, 1.7, 0), Vector3(-120, 3.0, 0)],
		# Low grazing shot along Cross +100 — the worst offender before the fix (was 19 m rise).
		["cross100", Vector3(60, 1.7, 100), Vector3(-100, 2.0, 100)],
		# High overview from the SE corner: whole town flat, hills ringing the perimeter.
		["overview", Vector3(140, 90, 150), Vector3(0, 0, 0)],
	]
	await process_frame
	await process_frame
	for i in range(4):   # let the terrain shader / grass MultiMesh settle
		await process_frame

	var dir := "user://town_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	for shot in shots:
		cam.global_position = shot[1]
		cam.look_at(shot[2], Vector3.UP)
		await process_frame
		await process_frame
		await process_frame
		var img := get_root().get_texture().get_image()
		var path := "%s/%s.png" % [dir, shot[0]]
		img.save_png(path)
		print("wrote ", ProjectSettings.globalize_path(path))
	quit(0)

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

	# Eye-level shots are seated ON the terrain (height_at + 1.7 m) so they frame the ROAD SURFACE the
	# way a standing player sees it — the map now has real rolling elevation, so a fixed Y would clip.
	var eye := func(x, z): return Vector3(x, Terrain.height_at(grid, x, z) + 1.7, z)
	var aim := func(x, z): return Vector3(x, Terrain.height_at(grid, x, z) + 1.5, z)
	var shots := [
		# Standing on the Main Avenue looking N up the spine (the road the owner walks).
		["ave_north", eye.call(0, 40), aim.call(0, -120)],
		# Standing at the central square looking W down Center-0 cross street toward the countryside.
		["cross_west", eye.call(-20, 0), aim.call(-118, 0)],
		# Eye-level along Cross +100 — the worst offender before (was 19 m rise / wavy grade).
		["cross100", eye.call(60, 100), aim.call(-118, 100)],
		# Standing on the SW cross street looking across the rolling town toward the far side.
		["cross_roll", eye.call(-90, -50), aim.call(90, -50)],
		# High overview from the SE: rolling town + graded roads, hills ringing the perimeter.
		["overview", Vector3(150, 95, 160), Vector3(0, 3, 0)],
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

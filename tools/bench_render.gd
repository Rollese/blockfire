extends SceneTree
## GPU fill-rate / post-FX benchmark for conquest_town. Renders a FIXED camera with vsync
## DISABLED, discards warmup frames, and reports the median frame time / fps over a steady
## window so the per-pixel cost of each post-FX can be isolated. Same world-build path as
## tools/render_town_shots.gd (client.tscn env + Terrain + WorldRenderer). No server, no HUD,
## no pawns/buildings — deliberately isolates terrain + scenery + the WorldEnvironment post-FX
## (the "empty grass still <60fps" repro). Run on a REAL GPU (laptop Wayland), NOT --headless:
##   BF_BENCH_VOLFOG=0 godot --path . -s res://tools/bench_render.gd --rendering-driver vulkan
## Env vars (all optional):
##   BF_BENCH_SSAO / BF_BENCH_GLOW / BF_BENCH_VOLFOG / BF_BENCH_FOG  = 0|1 (default 1 = on)
##   BF_BENCH_SCALE = 3d render scale, e.g. 0.6 (default 1.0)
##   BF_BENCH_SPOT  = grass | street   (default grass = open terrain, minimal geometry)
##   BF_BENCH_FRAMES = measured frames (default 240) ; BF_BENCH_WARMUP (default 90)
##   BF_BENCH_RES = WxH window size (default 1920x1080)

const MAP_PATH := "res://maps/conquest_town.json"

func _envf(name: String, def: float) -> float:
	var v := OS.get_environment(name)
	return def if v == "" else float(v)

func _envb(name: String, def := true) -> bool:
	var v := OS.get_environment(name)
	return def if v == "" else (v != "0" and v.to_lower() != "false")

func _initialize() -> void:
	# vsync OFF so frame time reflects true GPU cost, not the refresh cap.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var res_s := OS.get_environment("BF_BENCH_RES")
	var res := Vector2i(1920, 1080)
	if res_s.find("x") > 0:
		res = Vector2i(int(res_s.split("x")[0]), int(res_s.split("x")[1]))
	var root := get_root()
	root.size = res

	var scale := _envf("BF_BENCH_SCALE", 1.0)
	root.scaling_3d_scale = scale

	var scene: PackedScene = load("res://client/client.tscn")
	var world: Node3D = scene.instantiate() as Node3D
	root.add_child(world)
	var cam: Camera3D = world.get_node("Camera3D") as Camera3D
	cam.current = true

	# Apply post-FX toggles to the live WorldEnvironment (same env the real client uses).
	var we := world.get_node("WorldEnvironment") as WorldEnvironment
	var env: Environment = we.environment
	env.ssao_enabled = _envb("BF_BENCH_SSAO")
	env.glow_enabled = _envb("BF_BENCH_GLOW")
	env.volumetric_fog_enabled = _envb("BF_BENCH_VOLFOG")
	env.fog_enabled = _envb("BF_BENCH_FOG")

	# Directional (sun) shadow is another per-pixel cost worth isolating.
	var sun := world.get_node("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = _envb("BF_BENCH_SHADOW")

	var map: MapDef = MapDef.load_file(MAP_PATH)
	if map == null:
		push_error("bench: failed to load map"); quit(1); return
	var grid = Terrain.load_for_map(map, "res://maps", Callable())
	var r := WorldRenderer.new()
	world.add_child(r)
	r.set_terrain(grid)
	r.setup(map, cam)

	# Let the tree/window settle before aiming the camera (look_at needs it in-tree).
	await process_frame
	await process_frame
	var eye := func(x, z): return Vector3(x, Terrain.height_at(grid, x, z) + 1.7, z)
	var aim := func(x, z): return Vector3(x, Terrain.height_at(grid, x, z) + 1.5, z)
	var spot := OS.get_environment("BF_BENCH_SPOT")
	var from: Vector3
	var to: Vector3
	if spot == "street":
		from = eye.call(0, 40); to = aim.call(0, -120)   # down Main Avenue (some trees)
	else:
		from = eye.call(120, 120); to = aim.call(240, 240) # open perimeter grass toward countryside
	cam.global_position = from
	cam.look_at(to, Vector3.UP)

	var warmup := int(_envf("BF_BENCH_WARMUP", 90.0))
	var frames := int(_envf("BF_BENCH_FRAMES", 240.0))
	for i in warmup:
		await process_frame
	var samples := PackedFloat32Array()
	var prev := Time.get_ticks_usec()
	for i in frames:
		await process_frame
		var now := Time.get_ticks_usec()
		samples.append(float(now - prev) / 1000.0)   # ms
		prev = now
	var arr := Array(samples)
	arr.sort()
	var med: float = arr[arr.size() / 2]
	var p95: float = arr[int(arr.size() * 0.95)]
	var shadow_on := 1 if (sun != null and sun.shadow_enabled) else 0
	print("[bench] spot=%s ssao=%d glow=%d volfog=%d fog=%d shadow=%d scale=%.2f res=%dx%d -> median %.2f ms (%.1f fps)  p95 %.2f ms" % [
		("street" if spot == "street" else "grass"),
		int(env.ssao_enabled), int(env.glow_enabled), int(env.volumetric_fog_enabled), int(env.fog_enabled),
		shadow_on, scale, res.x, res.y, med, 1000.0 / med, p95])
	quit()

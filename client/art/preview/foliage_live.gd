extends Node3D
## Live, interactive foliage viewer (PROTOTYPE) — opens a real window and slowly ORBITS the TreeKit /
## RockKit set so it can be watched on a real GPU (true colour, unlike the offscreen PNG tool). Meant to
## be launched directly: godot --path . client/art/preview/foliage_live.tscn
## Controls: W/S = closer/further, Q/E = raise/lower camera, A/D = orbit speed, Space = pause, Esc = quit.

var _cam: Camera3D
var _angle := 0.6
var _radius := 13.0
var _height := 5.0
var _speed := 0.25
var _paused := false
var _center := Vector3(0.0, 4.5, -6.0)

func _ready() -> void:
	_setup_env()
	_populate()
	_cam = Camera3D.new()
	_cam.fov = 60.0
	add_child(_cam)
	_cam.make_current()
	set_process(true)

func _process(dt: float) -> void:
	if not _paused:
		_angle += dt * _speed
	var pos := _center + Vector3(sin(_angle) * _radius, _height, cos(_angle) * _radius)
	_cam.look_at_from_position(pos, _center, Vector3.UP)

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match (e as InputEventKey).keycode:
			KEY_ESCAPE: get_tree().quit()
			KEY_W: _radius = maxf(4.0, _radius - 1.0)
			KEY_S: _radius = minf(40.0, _radius + 1.0)
			KEY_Q: _height = minf(20.0, _height + 0.5)
			KEY_E: _height = maxf(0.5, _height - 0.5)
			KEY_A: _speed = maxf(0.0, _speed - 0.1)
			KEY_D: _speed += 0.1
			KEY_SPACE: _paused = not _paused

func _setup_env() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(160, 160)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.62, 0.55, 0.40); gm.roughness = 1.0
	ground.material_override = gm
	add_child(ground)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -120, 0)
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	add_child(sun)

	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.24, 0.44, 0.78)
	sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.92)
	sky_mat.ground_horizon_color = Color(0.75, 0.72, 0.62)
	sky_mat.ground_bottom_color = Color(0.55, 0.50, 0.42)
	var sky := Sky.new(); sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.0010
	env.fog_light_color = Color(0.78, 0.82, 0.88)
	env.fog_aerial_perspective = 0.25
	var we := WorldEnvironment.new(); we.environment = env
	add_child(we)

func _populate() -> void:
	var hero := TreeKit.build(3, 1.15)
	hero.position = Vector3(0.0, 0.0, -6.0)
	add_child(hero)
	for i in 3:
		var t := TreeKit.build(20 + i, [0.9, 1.05, 0.8][i])
		t.position = Vector3(-14.0 + i * 11.0, 0.0, -16.0)
		add_child(t)

	var patch := RockKit.build_patch(1, 4.5)
	patch.position = Vector3(3.0, 0.0, 2.0)
	add_child(patch)
	var cap := CapsuleMesh.new(); cap.radius = 0.3; cap.height = 1.8
	var cm := MeshInstance3D.new(); cm.mesh = cap; cm.position = Vector3(3.0, 0.9, 2.0)
	var cmat := StandardMaterial3D.new(); cmat.albedo_color = Color(0.2, 0.35, 0.55); cmat.roughness = 1.0
	cm.material_override = cmat
	add_child(cm)

	for b in [[30, 1.4, Vector3(-4.0, 0.0, 1.0)], [31, 1.0, Vector3(-6.5, 0.0, 3.5)]]:
		var r := RockKit.build(b[0], b[1])
		r.position = b[2]
		add_child(r)

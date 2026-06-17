extends Node
## Client composition root — M7 C1 (rendered client).
## Wires all client-side components; owns NO authority or rule logic (AGENTS.md §7).
## Authority lives on the server; this file connects UI/input/prediction/rendering only.

const Protocol := preload("res://shared/net/protocol.gd")
const MAP_PATH := "res://maps/conquest_proving_grounds.json"   # default; override with --map=<name>

# ---- network ----------------------------------------------------------------
var _net: NetHost
var _server_ip := "127.0.0.1"
var _port := 27015
var _player_name := "Player"
var _peer: ENetPacketPeer

# ---- identity / tick --------------------------------------------------------
var my_id := 0
var _client_tick := 0
var _last_snapshot_seq := 0
var _last_server_tick := 0
var _elapsed := 0.0

# ---- components (all non-scene, headless-safe) ------------------------------
var _settings: ClientSettings
var _map: MapDef
var _conquest: ConquestState
var _wv: WorldView
var _pred: Prediction
var _wpred: WeaponPredictor
var _input_ctrl: InputController
var _hud_model: HudModel

# ---- scene nodes (created after WELCOME) ------------------------------------
var _scene_root: Node3D        # ClientWorld node3D
var _camera: Camera3D
var _renderer: WorldRenderer
var _hud_view: HudView
var _deploy_menu: DeployMenu
var _settings_menu: SettingsMenu

# ---- state flags ------------------------------------------------------------
var _scene_built := false
var _deploy_menu_populated := false
var _was_alive: bool = false
var _match_state: Dictionary = {}
var _auto_deploy_ref: int = -1    # --deploy=N arg; -1 = not set
var _auto_deploy_sent := false    # only send once
var _dbg_accum := 0.0             # 1 Hz input/deploy diagnostic accumulator
var _novsync := false             # --novsync: disable vsync (perf diagnostic)
var _map_path: String = MAP_PATH  # --map=<name> overrides (must match server + bots)

# ---- configure (called by bootstrap before add_child) -----------------------
func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_player_name = String(args.get("name", _player_name))
	if args.has("deploy"):
		_auto_deploy_ref = int(args["deploy"])
	_novsync = args.has("novsync")
	if args.has("map"):
		_map_path = "res://maps/%s.json" % String(args["map"])

# ---- _ready -----------------------------------------------------------------
func _ready() -> void:
	# 1. Load settings
	_settings = ClientSettings.new()
	_settings.load_from()

	# 2. Load map + initial conquest state
	_map = MapDef.load_file(_map_path)
	if _map == null:
		push_error("[client] failed to load map: %s" % _map_path)
	_conquest = ConquestState.new(_map)

	# 3. Create non-scene components
	_wv = WorldView.new()
	_pred = Prediction.new()
	_wpred = WeaponPredictor.new()
	_hud_model = HudModel.new()

	# 4. InputController must be in the tree so _input() fires
	_input_ctrl = InputController.new()
	add_child(_input_ctrl)

	# 5. Network
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(_on_connected)
	_net.packet_received.connect(_on_packet)
	_peer = _net.start_client(_server_ip, _port)
	if _peer == null:
		push_error("[client] failed to create ENet host")
		return
	print("[client] connecting to %s:%d ..." % [_server_ip, _port])

# ---- physics tick -----------------------------------------------------------
func _physics_process(delta: float) -> void:
	_net.poll()
	_elapsed += delta

	if my_id == 0:
		return   # not yet welcomed

	var ss: EntityState = _wv.self_state()
	var deployed: bool = ss != null and ss.alive

	# Alive but with the settings menu open: free the cursor and pause input so the player can
	# click the menu without walking/looking. (Without this, the per-tick capture_mouse() below
	# re-grabs the cursor every frame and the centered menu is unclickable.)
	var menu_open: bool = _settings_menu != null and _settings_menu.visible

	if deployed and menu_open:
		if _scene_built:
			_input_ctrl.release_mouse()
			_input_ctrl.drain_look()
			if _deploy_menu != null:
				_deploy_menu.visible = false
	elif deployed:
		# Gather local input and run prediction
		var cmd: Dictionary = _input_ctrl.gather(_settings)
		_pred.record_cmd(_client_tick, cmd)

		var buttons: int = int(cmd["buttons"])
		var sprinting: bool = bool(buttons & InputCommand.BTN_SPRINT) \
			and _pred.predicted.stance == Stance.STAND
		var firing: bool = bool(buttons & InputCommand.BTN_FIRE)

		# Predict weapon state — drop_shoot=false here; server gates authoritatively,
		# and SELF_STATE reconciles the client's mag each tick so divergence is transient.
		# A true return means a shot fired this tick -> draw a tracer for immediate feedback.
		if _wpred.step(_client_tick, firing, sprinting, false) and _renderer != null:
			_renderer.fire_tracer(_elapsed)

		if buttons & InputCommand.BTN_RELOAD:
			_wpred.begin_reload(_client_tick)

		# Send input to server
		_net.send_to(_peer, NetHost.CHANNEL_INPUT,
			InputCommand.encode(
				_client_tick, _last_snapshot_seq,
				float(cmd["move_x"]), float(cmd["move_y"]),
				float(cmd["yaw"]), float(cmd["pitch"]),
				buttons, _last_server_tick),
			0)  # unreliable-sequenced

		_client_tick += 1

		if _scene_built:
			_input_ctrl.capture_mouse()

		# Hide deploy menu while alive
		if _scene_built and _deploy_menu != null:
			_deploy_menu.visible = false
	else:
		# Not deployed — show deploy menu and release mouse
		if _scene_built:
			_input_ctrl.release_mouse()
			if _deploy_menu != null:
				_deploy_menu.visible = true

		# Auto-deploy once (--deploy arg; same intent as clicking the button)
		if _auto_deploy_ref >= 0 and not _auto_deploy_sent:
			_auto_deploy_sent = true
			_send_deploy_request(_auto_deploy_ref)

# ---- render frame -----------------------------------------------------------
func _process(_dt: float) -> void:
	if not _scene_built:
		return

	_renderer.update(_wv, _pred, _elapsed, _settings.fov)

	var ctx: Dictionary = {
		"weapon_predictor": _wpred,
		"tick": _client_tick,
		"self_pos": _pred.predicted.pos,
		"self_yaw": _pred.predicted.yaw,
		"objectives": _objectives(),
		"match_state": _match_state,
		"point_positions": _point_positions(),
		"capture_radius": 8.0,
		"now": _elapsed,
	}
	_hud_view.render(_hud_model.build(ctx))

	# Settings menu toggle
	if Input.is_action_just_pressed("menu"):
		if _settings_menu != null:
			_settings_menu.visible = not _settings_menu.visible

	# Keep deploy menu visible only when undeployed AND the settings menu isn't up — otherwise the
	# two full-screen overlays stack (double-dimmed backdrop + dead spawn buttons behind settings).
	if _deploy_menu != null:
		var ss: EntityState = _wv.self_state()
		var deployed: bool = ss != null and ss.alive
		var settings_open: bool = _settings_menu != null and _settings_menu.visible
		_deploy_menu.visible = not deployed and not settings_open

	# --- input/deploy diagnostic (1 Hz) ----------------------------------------
	_dbg_accum += _dt
	if _dbg_accum >= 1.0:
		_dbg_accum = 0.0
		var dss: EntityState = _wv.self_state()
		print("[client-dbg] deployed=%s mouse_mode=%d menu_vis=%s refs=%d motion=%d w=%s fire=%s" % [
			str(dss != null and dss.alive), int(Input.mouse_mode),
			str(_deploy_menu.visible if _deploy_menu != null else false),
			(_deploy_menu.refs.size() if _deploy_menu != null else 0),
			_input_ctrl.motion_events,
			str(Input.is_action_pressed("move_fwd")),
			str(Input.is_action_pressed("fire"))])

# ---- connect callback -------------------------------------------------------
func _on_connected(peer: ENetPacketPeer) -> void:
	print("[client] connected — sending HELLO (manual deploy)")
	# auto_deploy=false: we want MANUAL deploy via the DeployMenu (AGENTS.md §7 — no client authority)
	_net.send_to(peer, NetHost.CHANNEL_CONTROL,
		Protocol.encode_hello(_player_name, false),
		ENetPacketPeer.FLAG_RELIABLE)

# ---- packet handler ---------------------------------------------------------
func _on_packet(_from: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			_handle_welcome(bytes)
		Protocol.Msg.REJECT:
			print("[client] REJECTED: %s" % Protocol.body_reader(bytes).get_utf8_string())
		Protocol.Msg.SNAPSHOT:
			_handle_snapshot(bytes)
		Protocol.Msg.SELF_STATE:
			_handle_self_state(bytes)
		Protocol.Msg.DAMAGE_EVENT:
			var d: Dictionary = Protocol.decode_damage_event(bytes)
			_hud_model.push_damage(float(d["bearing"]), int(d["amount"]), _elapsed)
		Protocol.Msg.KILL:
			var k: Dictionary = Protocol.decode_kill(bytes)
			_hud_model.push_kill(k, _elapsed)
		Protocol.Msg.MATCH_STATE:
			_handle_match_state(bytes)

# ---- WELCOME ----------------------------------------------------------------
func _handle_welcome(bytes: PackedByteArray) -> void:
	var w: Dictionary = Protocol.decode_welcome(bytes)
	my_id = int(w["id"])
	var tick_rate: int = int(w["tick_rate"])
	var cls: int = int(w["class"])

	_wv.set_local_id(my_id)
	_wpred.set_weapon(Loadout.weapon_for(cls))

	print("[client] WELCOME — id=%d tick_rate=%dHz class=%d" % [my_id, tick_rate, cls])

	# Build the 3D scene
	_build_scene()

# ---- SNAPSHOT ---------------------------------------------------------------
func _handle_snapshot(bytes: PackedByteArray) -> void:
	var hdr: Dictionary = _wv.apply_snapshot(bytes, _elapsed)
	_last_snapshot_seq = maxi(_last_snapshot_seq, int(hdr["seq"]))
	_last_server_tick = int(hdr["server_tick"])

	var ss: EntityState = _wv.self_state()
	var alive: bool = ss != null and ss.alive
	# On the alive->dead transition, force the deploy menu to re-populate with CURRENT
	# point ownership (it may have changed since the last deploy).
	if _was_alive and not alive:
		_deploy_menu_populated = false
	_was_alive = alive
	if alive:
		# Reconcile movement prediction from authoritative position + pitch
		_pred.reconcile_full(ss.pos, ss.yaw, ss.pitch, int(hdr["last_input_tick"]))
		if _scene_built and _deploy_menu != null:
			if not _deploy_menu_populated:
				_deploy_menu.populate(ss.team, _map, _conquest)
				_deploy_menu_populated = true
			_deploy_menu.visible = false
	else:
		# Dead / not yet deployed — show deploy menu (re-populated from current conquest)
		if _scene_built and _deploy_menu != null:
			if not _deploy_menu_populated and ss != null:
				_deploy_menu.populate(ss.team, _map, _conquest)
				_deploy_menu_populated = true
			_deploy_menu.visible = true

# ---- SELF_STATE -------------------------------------------------------------
func _handle_self_state(bytes: PackedByteArray) -> void:
	var d: Dictionary = Protocol.decode_self_state(bytes)
	# Switch weapon if server assigned a different one (e.g. class change)
	if int(d["weapon"]) != _wpred.weapon:
		_wpred.set_weapon(int(d["weapon"]))
	# Reconcile ammo from authority — no client rule logic, just snap
	_wpred.reconcile(int(d["mag"]), bool(d["reloading"]), int(d["reload_remaining"]), _client_tick)

# ---- MATCH_STATE ------------------------------------------------------------
func _handle_match_state(bytes: PackedByteArray) -> void:
	_match_state = Protocol.decode_match_state(bytes)
	# Mirror point ownership into local ConquestState so DeployMenu sees current owners
	var pts: Array = _match_state.get("points", [])
	for i in mini(pts.size(), _conquest.points.size()):
		_conquest.points[i]["owner"] = int(pts[i]["owner"])

# ---- scene build (post-WELCOME) --------------------------------------------
func _build_scene() -> void:
	if _scene_built:
		return

	# Load and instantiate client.tscn (ClientWorld + Camera3D + HUD CanvasLayer)
	var scene: PackedScene = load("res://client/client.tscn")
	if scene == null:
		push_error("[client] failed to load client.tscn")
		return
	var world_node: Node3D = scene.instantiate() as Node3D
	add_child(world_node)

	_scene_root = world_node
	_camera = world_node.get_node("Camera3D") as Camera3D

	# WorldRenderer — added under ClientWorld
	_renderer = WorldRenderer.new()
	world_node.add_child(_renderer)
	_renderer.setup(_map, _camera)

	# HUD layer
	var hud_layer: CanvasLayer = world_node.get_node("HUD") as CanvasLayer

	# HudView
	_hud_view = HudView.new()
	hud_layer.add_child(_hud_view)

	# DeployMenu
	_deploy_menu = DeployMenu.new()
	_deploy_menu.visible = true   # visible until deployed
	hud_layer.add_child(_deploy_menu)
	_deploy_menu.deploy_requested.connect(_on_deploy_requested)

	# SettingsMenu
	_settings_menu = SettingsMenu.new()
	_settings_menu.visible = false
	hud_layer.add_child(_settings_menu)
	_settings_menu.bind_settings(_settings)
	_settings_menu.settings_applied.connect(_on_settings_applied)

	_scene_built = true
	if _novsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		print("[client] vsync DISABLED (--novsync)")
	print("[client] scene built")

# ---- deploy request helpers -------------------------------------------------
func _on_deploy_requested(spawn_ref: int) -> void:
	_send_deploy_request(spawn_ref)

func _send_deploy_request(spawn_ref: int) -> void:
	_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
		Protocol.encode_deploy_request(spawn_ref),
		ENetPacketPeer.FLAG_RELIABLE)
	print("[client] deploy requested ref=%d" % spawn_ref)
	if _scene_built and _deploy_menu != null:
		_deploy_menu.set_awaiting(true)

# ---- settings live-update ---------------------------------------------------
func _on_settings_applied(new_settings: ClientSettings) -> void:
	_settings = new_settings
	# sensitivity and fov are read each frame from _settings — already live

# ---- helpers ----------------------------------------------------------------
func _objectives() -> Array:
	if _map == null:
		return []
	var out: Array = []
	var pts: Array = _match_state.get("points", [])
	for i in _map.points.size():
		var owner: int = int(pts[i]["owner"]) if i < pts.size() else -1
		out.append({"pos": _map.points[i]["pos"], "owner": owner})
	return out

func _point_positions() -> Array:
	if _map == null:
		return []
	var out: Array = []
	for pt: Dictionary in _map.points:
		out.append(pt["pos"])
	return out

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
# Input redundancy: each INPUT packet re-sends the last N frames so the server recovers a dropped
# packet from the next one's copy (see input_command.gd / InputBuffer). Frames are stored already
# in wire form (aim_yaw incl. the +PI flip, the view tick captured at generation time).
const INPUT_REDUNDANCY := 3
var _input_history: Array = []
var _elapsed := 0.0
# Render interpolation: the predicted eye at the previous/current physics tick. The camera renders
# a lerp between them by the physics-tick fraction, so 30 Hz prediction looks smooth at 60 Hz.
var _prev_eye := Vector3.ZERO
var _curr_eye := Vector3.ZERO
var _eye_init := false
# Reconcile smoothing: residual server-correction offset, eased to zero in render so a correction
# doesn't snap the camera. Only REAL mispredictions (above the deadzone) are smoothed — tiny
# per-tick corrections (sub-mm quantization) are ignored so the render interpolation stays intact.
var _pos_err := Vector3.ZERO
var _reconciled := false
const RECON_DEADZONE := 0.04   # corrections under this (m) are noise — left to normal interpolation
const RECON_SNAP := 2.5        # corrections over this (m) snap (respawn/teleport), not smoothed
const RECON_SMOOTH := 13.0     # per-second decay of _pos_err (~a correction fades over ~150 ms)
# DBNO downed screen
var _downed_since := -1.0      # _elapsed when the current down began (-1 = not downed)
var _giveup_hold := 0.0        # seconds the give-up key (jump) has been held while downed
var _giveup_sent := false
const BLEEDOUT_SECS := 8.0     # Revive |BLEEDOUT_FLOOR|/BLEED_RATE / TICK_RATE = 240/30
const GIVEUP_HOLD := 0.8       # seconds to hold to confirm give-up (avoid accidental skip)

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
var _audio: AudioDirector   # M7-P2 spatial-audio orchestrator (presentation-only, AGENTS.md §7)
const MAX_VOICES := 32      # finite concurrent voices at 128p (audio.md §10 Q1; owner-tunable)

# ---- state flags ------------------------------------------------------------
var _scene_built := false
var _deploy_menu_populated := false
var _awaiting_deploy := false   # true after a DEPLOY_REQUEST, until deployed or recovery
var _await_snaps := 0           # snapshots elapsed while awaiting (server-reject recovery)
var _was_alive: bool = false
var _died_at: float = -1.0                  # _elapsed at the last death; drives the respawn cooldown
const RESPAWN_COOLDOWN_S := 5.0             # mirrors server RESPAWN_DELAY_TICKS (150 @ 30 Hz)
var _match_state: Dictionary = {}
var _auto_deploy_ref: int = -1    # --deploy=N arg; -1 = not set
var _auto_deploy_sent := false    # only send once
var _flash_test := false          # --flash-test: force the flashbang white-out on (visual QA)
var _suppress_test := false        # --suppress-test: force the suppression screen FX on (visual QA)
var _shot_after := -1.0           # --shot-after=N: auto-save a screenshot N secs after launch, then quit
var _shot_done := false
var _dbg_accum := 0.0             # 1 Hz input/deploy diagnostic accumulator
var _novsync := false             # --novsync: disable vsync (perf diagnostic)
var _map_path: String = MAP_PATH  # --map=<name> overrides (must match server + bots)

# ---- C3 state ---------------------------------------------------------------
var _throwables: Array = []        # latest throwable list from SELF_STATE
var _being_revived: bool = false   # latest "a teammate is reviving me" flag from SELF_STATE
var _suppression: float = 0.0      # latest own-suppression scalar from SELF_STATE (M5.5-P2; M7 screen FX)
var _blind_ticks: int = 0          # latest remaining flashbang-blind ticks from SELF_STATE (M5.5-P3 white-out)
var _revive_hold: float = 0.0      # seconds the interact key has been held on a revive target

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
	_flash_test = args.has("flash-test")            # visual QA: force the flashbang white-out
	_suppress_test = args.has("suppress-test")      # visual QA: force the suppression screen FX
	_shot_after = float(args.get("shot-after", -1.0))  # automated screenshot then quit

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
	if _map != null:
		_pred.world_half = _map.world_half   # clamp local prediction to the map like the server
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
	var menu_open: bool = (_settings_menu != null and _settings_menu.visible) \
		or (_hud_view != null and _hud_view.is_squad_menu_open())

	if deployed and menu_open:
		if _scene_built:
			_input_ctrl.release_mouse()
			_input_ctrl.drain_look()
			if _deploy_menu != null:
				_deploy_menu.visible = false
	elif deployed:
		# Mirror authoritative downed state into the predictor so it crawls (1 m/s) like the server
		# instead of predicting full-speed movement the server rejects (the down-state rubber-band).
		_pred.predicted.is_downed = ss.is_downed
		# Gather local input and run prediction
		var cmd: Dictionary = _input_ctrl.gather(_settings)
		if _photo_mode:
			# Freeze the pawn while free-flying — WASD drives the camera, not the soldier. Keep
			# yaw/pitch so look still works; zero movement + buttons so nothing is sent as intent.
			cmd["move_x"] = 0.0
			cmd["move_y"] = 0.0
			cmd["buttons"] = 0
		_pred.record_cmd(_client_tick, cmd)

		var buttons: int = int(cmd["buttons"])
		var sprinting: bool = bool(buttons & InputCommand.BTN_SPRINT) \
			and _pred.predicted.stance == Stance.STAND
		# No firing while downed — the server ignores it, so suppress the local tracer/ammo
		# prediction too (otherwise a downed player still sees their own tracers).
		var firing: bool = bool(buttons & InputCommand.BTN_FIRE) and not _pred.predicted.is_downed

		# Predict weapon state — drop_shoot=false here; server gates authoritatively,
		# and SELF_STATE reconciles the client's mag each tick so divergence is transient.
		# A true return means a shot fired this tick -> draw a tracer for immediate feedback.
		if _wpred.step(_client_tick, firing, sprinting, false) and _renderer != null:
			_renderer.fire_tracer(_elapsed)
			if _audio != null:
				_audio.play_at(_fire_event_for(_wpred.weapon), _pred.predicted.eye_position())

		if buttons & InputCommand.BTN_RELOAD:
			var _was_reloading: bool = _wpred.reloading
			_wpred.begin_reload(_client_tick)
			if not _was_reloading and _wpred.reloading and _audio != null:
				_audio.play_2d("reload")   # only on the actual reload-start transition

		# Send input to server. The server rebuilds the shot ray from Combat._forward(yaw,pitch),
		# which points opposite the Godot camera, so send yaw+PI to make the authoritative aim
		# match where the crosshair points. Movement is world-space (move_x/y) so it's unaffected.
		var aim_yaw: float = wrapf(float(cmd["yaw"]) + PI, -PI, PI)
		# Append this tick's frame to the redundancy ring and send the last N. ack_seq is
		# per-packet (latest snapshot); each frame keeps its own view tick for lag comp.
		_input_history.append({
			"client_tick": _client_tick, "move_x": float(cmd["move_x"]), "move_y": float(cmd["move_y"]),
			"yaw": aim_yaw, "pitch": float(cmd["pitch"]), "buttons": buttons,
			"view_server_tick": _last_server_tick,
		})
		while _input_history.size() > INPUT_REDUNDANCY:
			_input_history.pop_front()
		_net.send_to(_peer, NetHost.CHANNEL_INPUT,
			InputCommand.encode_bundle(_last_snapshot_seq, _input_history),
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
			_input_ctrl.reset_prone()   # don't carry a prone toggle into the next life
			if _deploy_menu != null:
				_deploy_menu.visible = true

		# Auto-deploy once (--deploy arg; same intent as clicking the button)
		if _auto_deploy_ref >= 0 and not _auto_deploy_sent:
			_auto_deploy_sent = true
			_send_deploy_request(_auto_deploy_ref)

	# Render-interpolation: snapshot the predicted eye each physics tick. Snap (don't smear) on big
	# jumps — spawn/teleport/large reconcile — so a correction isn't dragged across a 33 ms tick.
	if _scene_built:
		var eye_now: Vector3 = _pred.predicted.eye_position()
		# On a real reconcile (or init/teleport) snap the interp base to the corrected eye — the
		# correction is carried/eased in _pos_err, so the per-tick lerp doesn't double-smear it.
		# Tiny corrections don't set _reconciled, so normal 30->60 interpolation is preserved.
		if not _eye_init or _reconciled or eye_now.distance_to(_curr_eye) > 5.0:
			_prev_eye = eye_now
			_eye_init = true
			_reconciled = false
		else:
			_prev_eye = _curr_eye
		_curr_eye = eye_now

# ---- screenshot capture -----------------------------------------------------
# F12 (or F9) saves a PNG of exactly what's on screen (incl. HUD) to ~/bf-shots/ so issues can be
# shown, not just described. Polled in _process (NOT _unhandled_input — the HUD/menu can swallow the
# key event), with edge detection so one press = one shot. The dev pulls them off the render host.
var _shot_key_down := false

func _poll_screenshot_key() -> void:
	var down := Input.is_physical_key_pressed(KEY_F12) or Input.is_physical_key_pressed(KEY_F9)
	if down and not _shot_key_down:
		_save_screenshot()
	_shot_key_down = down

func _save_screenshot() -> void:
	var tex := get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		push_warning("[shot] could not grab viewport image")
		return
	var dir := "%s/bf-shots" % OS.get_environment("HOME")
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace("T", "_").replace(":", "-")
	var path := "%s/shot_%s.png" % [dir, stamp]
	var err := img.save_png(path)
	if err == OK:
		print("[shot] saved %s" % path)
		if _audio != null:
			_audio.play_2d("ui_click")   # audible confirmation
	else:
		push_warning("[shot] save failed (err %d) -> %s" % [err, path])

# ---- photo / free-fly mode (admin) ------------------------------------------
# F8 toggles a detached free-flying camera with the viewmodel + HUD hidden, for clean fast screenshots.
# The pawn is frozen (movement/fire input zeroed) while active. WASD = fly, jump/crouch = up/down,
# sprint = faster.
var _photo_mode := false
var _photo_pos := Vector3.ZERO
var _photo_key_down := false

func _poll_photo_mode() -> void:
	var down := Input.is_physical_key_pressed(KEY_F8)
	if down and not _photo_key_down:
		_photo_mode = not _photo_mode
		if _photo_mode and _camera != null:
			_photo_pos = _camera.global_position
		if _hud_view != null:
			_hud_view.visible = not _photo_mode
		if _renderer != null:
			_renderer.set_viewmodel_hidden(_photo_mode)
		print("[photo] free-fly mode = %s" % _photo_mode)
	_photo_key_down = down

func _fly_photo_camera(dt: float) -> void:
	if _camera == null:
		return
	var b := _camera.global_transform.basis
	var f := Input.get_action_strength("move_fwd") - Input.get_action_strength("move_back")
	var s := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var u := Input.get_action_strength("jump") - Input.get_action_strength("crouch")
	var speed := (70.0 if Input.is_action_pressed("sprint") else 24.0) * dt
	_photo_pos += (-b.z * f + b.x * s + Vector3.UP * u) * speed
	_camera.global_position = _photo_pos

# ---- render frame -----------------------------------------------------------
func _process(_dt: float) -> void:
	_poll_screenshot_key()   # F12/F9 screenshot — works even before the scene is built
	# --shot-after=N: automated visual QA — save one screenshot N secs after launch, then quit.
	if _shot_after >= 0.0 and not _shot_done and _scene_built and _elapsed >= _shot_after:
		_shot_done = true
		_save_screenshot()
		get_tree().create_timer(0.5).timeout.connect(func() -> void: get_tree().quit())
	if not _scene_built:
		return
	_poll_photo_mode()       # F8 free-fly toggle (camera exists once the scene is built)

	# Render-rate look + camera-position interpolation, so a 30 Hz sim renders smoothly at 60 Hz.
	var ss0: EntityState = _wv.self_state()
	var deployed0: bool = ss0 != null and ss0.alive
	var menu_open0: bool = (_settings_menu != null and _settings_menu.visible) \
		or (_hud_view != null and _hud_view.is_squad_menu_open())
	if deployed0 and not menu_open0:
		_input_ctrl.update_look(_settings)   # apply accumulated mouse delta at render rate
	else:
		_input_ctrl.drain_look()
	_pos_err = _pos_err.lerp(Vector3.ZERO, clampf(_dt * RECON_SMOOTH, 0.0, 1.0))
	var eye: Vector3 = _prev_eye.lerp(_curr_eye, Engine.get_physics_interpolation_fraction()) + _pos_err

	if _audio != null:
		_audio.set_listener_pos(eye)   # spatial-audio listener tracks the rendered camera/eye

	if _wpred != null and not _photo_mode:
		_renderer.set_viewmodel_weapon(_wpred.weapon)   # show the RPG launcher etc., not always the AR
	var _t0 := Time.get_ticks_usec()
	_renderer.update(_wv, _pred, _elapsed, _settings.fov, _input_ctrl.yaw, _input_ctrl.pitch, eye, _dt)
	if _photo_mode:
		_fly_photo_camera(_dt)   # override the pawn-eye camera with the free-fly position
	var _t1 := Time.get_ticks_usec()

	var ctx: Dictionary = {
		"weapon_predictor": _wpred,
		"tick": _client_tick,
		"self_pos": _pred.predicted.pos,
		"self_yaw": _input_ctrl.yaw,   # client look yaw (camera), not the reconciled pawn yaw
		"objectives": _objectives(),
		"match_state": _match_state,
		"point_positions": _point_positions(),
		"capture_radius": 8.0,
		"now": _elapsed,
		# C3 additions
		"roster": _wv.roster(),
		"self_id": my_id,
		"entities": _build_entities(),
		"throwables": _throwables,
		"downed_mates": _downed_mates(),
		"vehicles_near": _vehicles_near(),
	}
	var _model := _hud_model.build(ctx)
	var _t2 := Time.get_ticks_usec()
	_hud_view.render(_model)
	var _t3 := Time.get_ticks_usec()
	# Per-section CPU timings surfaced on the perf overlay (permanent dev tool).
	_hud_view.perf_render_us = _t1 - _t0   # world: entity pool + interpolation + camera + tracers
	_hud_view.perf_build_us = _t2 - _t1    # HUD model build (incl. ctx: objectives/points)
	_hud_view.perf_hud_us = _t3 - _t2      # HUD view render (compass/ammo/tickets/…)

	# DBNO downed screen: bleed-out countdown, nearest-friendly distance, hold-to-give-up.
	var sds: EntityState = _wv.self_state()
	if sds != null and sds.alive and sds.is_downed:
		if _downed_since < 0.0:
			_downed_since = _elapsed
			_giveup_hold = 0.0
			_giveup_sent = false
		if Input.is_action_pressed("jump"):
			_giveup_hold += _dt
			if _giveup_hold >= GIVEUP_HOLD and not _giveup_sent and _peer != null:
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL, Protocol.encode_give_up(), ENetPacketPeer.FLAG_RELIABLE)
				_giveup_sent = true
		else:
			_giveup_hold = 0.0
		var secs_left: float = maxf(0.0, BLEEDOUT_SECS - (_elapsed - _downed_since))
		_hud_view.set_downed(true, secs_left, _nearest_friendly_dist(sds), clampf(_giveup_hold / GIVEUP_HOLD, 0.0, 1.0), _being_revived)
	elif _downed_since >= 0.0:
		_downed_since = -1.0
		_hud_view.set_downed(false, 0.0, -1.0, 0.0)

	# ---- C3: scoreboard hold (TAB) ------------------------------------------------
	if _hud_view != null:
		_hud_view.set_scoreboard_held(Input.is_action_pressed("scoreboard"))
		# Hide the alive-only combat HUD (ammo + throwable selector) while downed/dead/deploying.
		var hs: EntityState = _wv.self_state()
		_hud_view.set_alive_hud(hs != null and hs.alive and not hs.is_downed)
		# M5.5-P3 flashbang white-out from the SELF_STATE blind byte (cleared on death/deploy).
		# --flash-test forces a strong-but-translucent veil so the world shows through (visual QA);
		# it still routes through blind_intensity so the real render chain is exercised.
		var blinded := hs != null and hs.alive and not hs.is_downed
		var blind_ticks := 34 if _flash_test else (_blind_ticks if blinded else 0)
		_hud_view.set_blind(HudModel.blind_intensity(blind_ticks))
		# M5.5-P2 suppression screen FX from the SELF_STATE suppression byte (same gating as blind:
		# only while alive + not downed). --suppress-test forces a strong veil for visual QA.
		var supp := 0.8 if _suppress_test else (_suppression if blinded else 0.0)
		_hud_view.set_suppression(HudModel.suppression_intensity(supp))

	# ---- C3: revive intent (no self-recovery — a teammate must revive you, BattleBit-style) ----
	var sss: EntityState = _wv.self_state()
	var is_downed: bool = sss != null and sss.alive and sss.is_downed
	if is_downed:
		pass   # downed players have no self-bandage/self-revive; they wait for a teammate or bleed out
	else:
		# Revive intent: hold interact while the interaction prompt targets a downed mate.
		var ip = _model.get("interaction_prompt")
		var interact_held: bool = Input.is_action_pressed("interact")
		# Enter-vehicle intent: a single F press when the prompt offers a friendly vehicle.
		if ip != null and String(ip.get("action", "")) == "enter_vehicle" \
				and Input.is_action_just_pressed("interact") and _peer != null:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_vehicle_action(Protocol.VA_ENTER, int(ip["target"]), int(ip.get("seat", 0))),
				ENetPacketPeer.FLAG_RELIABLE)
		if ip != null and String(ip.get("action", "")) == "revive" and interact_held and _peer != null:
			_revive_hold += _dt
			var revive_time: float = float(Revive.REVIVE_TICKS) / 30.0
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_revive_action(int(ip["target"]), true), ENetPacketPeer.FLAG_RELIABLE)
			if _hud_view != null:
				_hud_view.set_revive_progress(clampf(_revive_hold / revive_time, 0.0, 1.0))
		else:
			if _revive_hold > 0.0 and _peer != null and ip != null \
					and String(ip.get("action", "")) == "revive":
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
					Protocol.encode_revive_action(int(ip["target"]), false), ENetPacketPeer.FLAG_RELIABLE)
			_revive_hold = 0.0
			if _hud_view != null:
				_hud_view.set_revive_progress(0.0)

	# ---- C3: one-shot actions (throw / throwable_cycle / gadget / squad_menu) ----
	var alive_and_deployed: bool = sss != null and sss.alive and not sss.is_downed
	if alive_and_deployed and _peer != null:
		# Throwable cycle
		if Input.is_action_just_pressed("throwable_cycle"):
			_hud_model.cycle_throwable(_throwables.size())

		# Throw: send grenade or RPG based on active throwable kind
		if Input.is_action_just_pressed("throw"):
			var throwables_model: Dictionary = _model.get("throwables", {})
			var tlist: Array = throwables_model.get("list", [])
			var active_idx: int = int(throwables_model.get("active", 0))
			if active_idx < tlist.size():
				var slot: Dictionary = tlist[active_idx]
				var kind: int = int(slot.get("kind", -1))
				# Aim direction: same camera-forward the server rebuilds for bullets
				var aim_dir: Vector3 = -Vector3(sin(_input_ctrl.yaw), 0.0,
					cos(_input_ctrl.yaw)).normalized()
				# Tilt by pitch so thrown arc matches the look direction
				var pitch: float = _input_ctrl.pitch
				aim_dir = Vector3(aim_dir.x * cos(pitch), sin(pitch), aim_dir.z * cos(pitch)).normalized()
				if kind == Grenade.FRAG or kind == Grenade.SMOKE:
					_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
						Protocol.encode_grenade_throw(aim_dir, kind), ENetPacketPeer.FLAG_RELIABLE)
				elif kind == 100:  # RPG
					_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
						Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE,
							_pred.predicted.pos, aim_dir, 0), ENetPacketPeer.FLAG_RELIABLE)

		# Left-click also fires the RPG when it's the equipped weapon. The RPG isn't a hit-scan
		# click weapon, so without this the primary-fire button feels dead for an RPG loadout.
		if Input.is_action_just_pressed("fire") and _has_rpg_equipped():
			var rad: Vector3 = -Vector3(sin(_input_ctrl.yaw), 0.0, cos(_input_ctrl.yaw)).normalized()
			var rpit: float = _input_ctrl.pitch
			rad = Vector3(rad.x * cos(rpit), sin(rpit), rad.z * cos(rpit)).normalized()
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE, _pred.predicted.pos, rad, 0),
				ENetPacketPeer.FLAG_RELIABLE)
			if _renderer != null:
				# Instant shooter feedback (muzzle flash + flying rocket); the server replays it to others.
				_renderer.fire_rocket(_pred.predicted.eye_position(), rad, _elapsed)

		# Gadget: non-throwable gadget action. Defaulting to C4 detonate; owner must verify
		# if their class uses a different primary gadget (e.g. repair, bag throw).
		if Input.is_action_just_pressed("gadget"):
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_gadget_action(Protocol.GA_C4_DETONATE,
					_pred.predicted.pos, Vector3.ZERO, 0), ENetPacketPeer.FLAG_RELIABLE)
			# OWNER VERIFY: GA_C4_DETONATE is the default; adapt to class loadout (repair/bag/etc.)

		# Squad menu (U): toggle the standalone squad-select overlay while alive.
		if Input.is_action_just_pressed("squad_menu") and _hud_view != null and sss != null and sss.alive:
			_hud_view.set_squad_menu_open(not _hud_view.is_squad_menu_open())

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
		Protocol.Msg.HITMARKER:
			var h: Dictionary = Protocol.decode_hitmarker(bytes)
			if _hud_view != null:
				_hud_view.flash_hitmarker(bool(h["headshot"]), bool(h["lethal"]))
			if _audio != null:
				_audio.play_2d("hitmarker")
		Protocol.Msg.MATCH_STATE:
			_handle_match_state(bytes)
		Protocol.Msg.ROSTER:
			_wv.set_roster(Protocol.decode_roster(bytes)["rows"])
		Protocol.Msg.DEATH_INFO:
			_hud_model.set_death_info(Protocol.decode_death_info(bytes))
			# Show the deploy/recap screen (same path as the alive->dead snapshot transition)
			_deploy_menu_populated = false
		Protocol.Msg.STRUCTURE_BASELINE:
			_wv.apply_structure_baseline(bytes)
		Protocol.Msg.STRUCTURE_DELTA:
			_wv.apply_structure_delta(bytes)
		Protocol.Msg.COLLAPSE:
			_wv.apply_collapse(Protocol.decode_collapse(bytes))
		Protocol.Msg.SHOT_FX:
			var fx: Dictionary = Protocol.decode_shot_fx(bytes)
			if _renderer != null:
				_renderer.tracer_from(fx["origin"], fx["dir"], _elapsed)
			if _audio != null:
				_audio.play_at("gunfire", fx["origin"])   # spatial remote-pawn gunfire
		Protocol.Msg.ROCKET_FX:
			var rfx: Dictionary = Protocol.decode_rocket_fx(bytes)
			if _renderer != null:
				_renderer.fire_rocket(rfx["origin"], rfx["dir"], _elapsed)   # remote rocket flies + launch flash

# ---- WELCOME ----------------------------------------------------------------
func _handle_welcome(bytes: PackedByteArray) -> void:
	var w: Dictionary = Protocol.decode_welcome(bytes)
	my_id = int(w["id"])
	var tick_rate: int = int(w["tick_rate"])
	var cls: int = int(w["class"])

	_wv.set_local_id(my_id)
	_wpred.set_weapon(Loadout.weapon_for(cls))

	# Adopt the server's map (authoritative) so roads/points/bases match the match the server is
	# running — no need to launch the client with a matching --map. Falls back to the locally loaded
	# map if the server sent nothing or we don't have that file.
	var server_map := String(w.get("map", ""))
	if server_map != "":
		var server_path := "res://maps/%s.json" % server_map
		if server_path != _map_path:
			var sm := MapDef.load_file(server_path)
			if sm != null:
				_map_path = server_path
				_map = sm
				_conquest = ConquestState.new(_map)
				print("[client] adopting server map: %s" % server_map)
			else:
				push_warning("[client] server map '%s' not found locally; keeping %s" % [server_map, _map_path])

	print("[client] WELCOME — id=%d tick_rate=%dHz class=%d map=%s" % [my_id, tick_rate, cls, _map_path.get_file().get_basename()])

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
		_pos_err = Vector3.ZERO   # drop any residual reconcile offset so respawn doesn't inherit it
		_reconciled = false
		_died_at = _elapsed   # start the respawn-cooldown clock
		if _hud_view != null:
			_hud_view.set_squad_menu_open(false)   # don't leave the squad overlay up over the deploy screen
	_was_alive = alive
	if alive:
		# Mirror downed state BEFORE reconcile so the replayed inputs crawl (1 m/s) on the very tick
		# the down/revive lands — otherwise that transition tick replays full-speed and rubber-bands.
		_pred.predicted.is_downed = ss.is_downed
		# Reconcile movement prediction from authoritative position + pitch. Smooth only a genuine
		# correction (deadzone..snap): ease it into the camera via _pos_err instead of snapping.
		var pre_pos: Vector3 = _pred.predicted.pos
		_pred.reconcile_full(ss.pos, ss.yaw, ss.pitch, int(hdr["last_input_tick"]))
		var cl: float = (pre_pos - _pred.predicted.pos).length()
		if cl > RECON_DEADZONE and cl <= RECON_SNAP:
			_pos_err += pre_pos - _pred.predicted.pos
			_reconciled = true
		elif cl > RECON_SNAP:
			_pos_err = Vector3.ZERO   # too large to smear (respawn/teleport) — snap
		if _scene_built and _deploy_menu != null:
			if not _deploy_menu_populated:
				var my_squad: int = _my_squad_id(ss.team)
				_deploy_menu.populate(ss.team, _map, _conquest,
					_build_squadmate_candidates(ss.team, my_squad),
					_build_vehicle_candidates(ss.team))
				_deploy_menu_populated = true
			_deploy_menu.visible = false
			_awaiting_deploy = false   # deploy confirmed — clear awaiting state
	else:
		# Dead / not yet deployed — show deploy menu (re-populated from current conquest).
		# Recovery: if we sent a deploy request but are STILL undeployed a few snapshots later,
		# the server rejected it (e.g. mate died) — un-stick the "awaiting" overlay and refresh
		# the spawn list so the player can re-pick instead of being trapped.
		if _awaiting_deploy:
			_await_snaps += 1
			if _await_snaps >= 12:
				_awaiting_deploy = false
				_deploy_menu_populated = false
				if _deploy_menu != null:
					_deploy_menu.set_awaiting(false)
		if _scene_built and _deploy_menu != null:
			if not _deploy_menu_populated and ss != null:
				var my_squad: int = _my_squad_id(ss.team)
				_deploy_menu.populate(ss.team, _map, _conquest,
					_build_squadmate_candidates(ss.team, my_squad),
					_build_vehicle_candidates(ss.team))
				_deploy_menu_populated = true
			_deploy_menu.visible = true
			if not _awaiting_deploy:
				_deploy_menu.set_respawn_cooldown(_respawn_cooldown_left())

# ---- SELF_STATE -------------------------------------------------------------
func _handle_self_state(bytes: PackedByteArray) -> void:
	var d: Dictionary = Protocol.decode_self_state(bytes)
	# Switch weapon if server assigned a different one (e.g. class change)
	if int(d["weapon"]) != _wpred.weapon:
		_wpred.set_weapon(int(d["weapon"]))
	# Reconcile ammo from authority — no client rule logic, just snap
	_wpred.reconcile(int(d["mag"]), bool(d["reloading"]), int(d["reload_remaining"]), _client_tick)
	# Store throwable list for HUD ctx (C3: SELF_STATE now carries per-kind counts)
	_throwables = d.get("throwables", [])
	_being_revived = bool(d.get("being_revived", false))   # downed-screen "being revived" indicator
	_suppression = float(d.get("suppression", 0.0))        # M5.5-P2: own suppression (M7 renders screen FX)
	_blind_ticks = int(d.get("blind_ticks", 0))            # M5.5-P3: remaining flashbang-blind ticks (white-out)

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
	_renderer.use_models = _settings.use_model_characters

	# HUD layer
	var hud_layer: CanvasLayer = world_node.get_node("HUD") as CanvasLayer

	# HudView
	_hud_view = HudView.new()
	hud_layer.add_child(_hud_view)
	_hud_view.squad_picked.connect(_on_squad_menu_pick)

	# DeployMenu
	_deploy_menu = DeployMenu.new()
	_deploy_menu.visible = true   # visible until deployed
	hud_layer.add_child(_deploy_menu)
	_deploy_menu.deploy_requested.connect(_on_deploy_requested)
	# C3 squad hook: Task 20 may add squad_selected(squad_id) to DeployMenu; wire it here.
	if _deploy_menu.has_signal("squad_selected"):
		_deploy_menu.squad_selected.connect(_on_squad_selected)

	# SettingsMenu
	_settings_menu = SettingsMenu.new()
	_settings_menu.visible = false
	hud_layer.add_child(_settings_menu)
	_settings_menu.bind_settings(_settings)
	_settings_menu.settings_applied.connect(_on_settings_applied)

	# AudioDirector — spatial-audio orchestrator (presentation-only). setup() before add_child so its
	# _ready() builds the voice players with the catalog ready. Spatializes relative to the Camera3D.
	var _acat := AudioCatalog.new()
	_acat.load_from("res://data/sounds.json")
	_audio = AudioDirector.new()
	_audio.setup(_acat, MAX_VOICES)
	world_node.add_child(_audio)
	_apply_master_volume()

	_scene_built = true
	if _novsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		print("[client] vsync DISABLED (--novsync)")
	print("[client] scene built")

# ---- deploy request helpers -------------------------------------------------
## Seconds left on the post-death respawn cooldown (0 when ready or never died).
func _respawn_cooldown_left() -> float:
	if _died_at < 0.0:
		return 0.0
	return maxf(0.0, RESPAWN_COOLDOWN_S - (_elapsed - _died_at))

func _on_deploy_requested(spawn_ref: int) -> void:
	_send_deploy_request(spawn_ref)

func _send_deploy_request(spawn_ref: int) -> void:
	if _respawn_cooldown_left() > 0.0:
		return   # respawn cooldown not elapsed — server would reject anyway
	_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
		Protocol.encode_deploy_request(spawn_ref),
		ENetPacketPeer.FLAG_RELIABLE)
	print("[client] deploy requested ref=%d" % spawn_ref)
	_awaiting_deploy = true
	_await_snaps = 0
	if _scene_built and _deploy_menu != null:
		_deploy_menu.set_awaiting(true)
	# Clear death recap so it doesn't show on the next respawn
	_hud_model.clear_death_info()

# ---- settings live-update ---------------------------------------------------
func _on_settings_applied(new_settings: ClientSettings) -> void:
	_settings = new_settings
	# sensitivity and fov are read each frame from _settings — already live
	_apply_master_volume()   # master volume slider now drives the audio Master bus

## Drive the audio Master bus from the (previously inert) master_volume setting.
func _apply_master_volume() -> void:
	var v: float = clampf(_settings.master_volume, 0.0, 1.0)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(v, 0.0001)))
	AudioServer.set_bus_mute(0, v <= 0.0)

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

## Build entities map id->{alive, is_downed, pos} from interpolated remotes + self.
func _build_entities() -> Dictionary:
	var out: Dictionary = {}
	var rem: Dictionary = _wv.remotes_at(_elapsed)
	for rid in rem:
		var e: EntityState = rem[rid]
		out[int(rid)] = {"alive": e.alive, "is_downed": e.is_downed, "pos": e.pos}
	# Include self from authoritative state (not predicted) so downed check is authoritative.
	var sself: EntityState = _wv.self_state()
	if sself != null:
		out[my_id] = {"alive": sself.alive, "is_downed": sself.is_downed, "pos": _pred.predicted.pos}
	return out

## [{id, dist}] for same-team DOWNED entities within REVIVE_RANGE of the local player.
## Proximity computation for UI prompt only — the server validates revive eligibility.
func _downed_mates() -> Array:
	var sself: EntityState = _wv.self_state()
	if sself == null or not sself.alive or sself.is_downed:
		return []
	var roster: Array = _wv.roster()
	var my_team: int = -1
	for rw in roster:
		if int(rw["id"]) == my_id:
			my_team = int(rw["team"]); break
	var rem: Dictionary = _wv.remotes_at(_elapsed)
	var self_pos: Vector3 = _pred.predicted.pos
	var out: Array = []
	for rid in rem:
		var e: EntityState = rem[rid]
		if not e.alive or not e.is_downed:
			continue
		# Same-team check via roster
		var e_team: int = -1
		for rw in roster:
			if int(rw["id"]) == int(rid):
				e_team = int(rw["team"]); break
		if e_team != my_team:
			continue
		var dist: float = self_pos.distance_to(e.pos)
		if dist <= Revive.REVIVE_RANGE:
			out.append({"id": int(rid), "dist": dist})
	return out

## [{vid, seat, dist}] for vehicles with a free seat within interact range.
## Uses WorldView.vehicles() (added in C2). Seat availability is client best-effort;
## the server validates on VA_ENTER. Owner should verify seat index in playtest.
func _vehicles_near() -> Array:
	var sself: EntityState = _wv.self_state()
	if sself == null or not sself.alive or sself.is_downed:
		return []
	var self_pos: Vector3 = _pred.predicted.pos
	const VEH_INTERACT_RANGE := 6.0   # metres; owner-tunable
	var out: Array = []
	var vehs: Dictionary = _wv.vehicles()
	for vid in vehs:
		var vs = vehs[vid]   # VehicleState
		if vs == null:
			continue
		var dist: float = self_pos.distance_to(vs.pos)
		if dist <= VEH_INTERACT_RANGE:
			# Use seat 0 as default; server validates and assigns the actual free seat on VA_ENTER.
			out.append({"vid": int(vid), "seat": 0, "dist": dist})
	return out

## Per-weapon gunfire cue, mapping the equipped weapon to its CC0 caliber sample. Unknown weapons
## fall back to the AR report ("gunfire"). RPG fires via the gadget path, not here.
func _fire_event_for(weapon_id: int) -> String:
	match weapon_id:
		Weapon.SMG: return "gunfire_smg"
		Weapon.DMR: return "gunfire_dmr"
		_: return "gunfire"

## True when the equipped weapon is the RPG — the server only includes the kind-100 throwable
## entry in SELF_STATE when c["weapon"] == Weapon.RPG, so its presence is the client's RPG signal.
func _has_rpg_equipped() -> bool:
	for t in _throwables:
		if int(t.get("kind", -1)) == 100:
			return true
	return false

## Return the local player's current squad_id from the roster (-1 if unknown).
func _my_squad_id(_team: int) -> int:
	for rw in _wv.roster():
		if int(rw["id"]) == my_id:
			return int(rw.get("squad", 0))
	return 0

## Build squadmate candidate array for DeploySpawn.enumerate().
## Filters WorldView roster to same-team + same-squad (excluding self), then joins with
## interpolated entity state for pos/alive/downed. Mates not in the interpolated view
## (out of range) are skipped — they'd fail server validation anyway.
## Returns Array of {pos, team, alive, downed, name}.
func _build_squadmate_candidates(my_team: int, my_squad: int) -> Array:
	var out: Array = []
	var roster: Array = _wv.roster()
	var rem: Dictionary = _wv.remotes_at(_elapsed)
	for rw in roster:
		var rid: int = int(rw["id"])
		if rid == my_id:
			continue
		if int(rw["team"]) != my_team:
			continue
		if int(rw["squad"]) != my_squad:
			continue
		# Only include mate if we have a current interpolated entity (in view).
		var e: EntityState = rem.get(rid)
		if e == null:
			continue
		out.append({
			"id": rid,   # stable pawn id — DeploySpawn keys squadmate refs by this, not array position
			"pos": e.pos,
			"team": e.team,
			"alive": e.alive,
			"downed": e.is_downed,
			"name": String(rw.get("name", "")),
		})
	return out

## Build vehicle candidate array for DeploySpawn.enumerate().
## All friendly vehicles from WorldView.vehicles() with at least one free seat.
## VehicleState has no team field; we accept all vehicles (server re-validates team ownership).
## free_seats is counted from seats[] (0 = empty slot). type_name is a display-only extra key.
## Returns Array of {pos, team, free_seats, type_name}.
func _build_vehicle_candidates(my_team: int) -> Array:
	var out: Array = []
	var vehs: Dictionary = _wv.vehicles()
	for vid in vehs:
		var vs: VehicleState = vehs[vid]
		if vs == null:
			continue
		# Count free seats: seats[i] == 0 means empty.
		var free_count: int = 0
		for occ in vs.seats:
			if int(occ) == 0:
				free_count += 1
		if free_count == 0:
			continue
		# VehicleState carries no team field — pass my_team as best-effort.
		# Server validates using its authoritative Vehicle.team; a mismatch is a no-op.
		out.append({
			"slot": int(vid) - Vehicle.ID_BASE,   # stable vehicle slot — ref key, not array position
			"pos": vs.pos,
			"team": my_team,
			"free_seats": free_count,
			"type_name": "transport",   # single vehicle type today; extend when catalog grows
		})
	return out

## Called when the deploy menu emits squad_selected(squad_id) (Task 20 hook).
func _on_squad_selected(squad_id: int) -> void:
	if _peer != null:
		_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
			Protocol.encode_set_squad(squad_id), ENetPacketPeer.FLAG_RELIABLE)

## U squad-overlay pick: send SET_SQUAD then close the overlay (cursor re-captures next frame).
func _on_squad_menu_pick(squad_id: int) -> void:
	_on_squad_selected(squad_id)
	if _hud_view != null:
		_hud_view.set_squad_menu_open(false)

## Distance to the nearest alive, standing teammate in view (for the downed screen). -1 if none.
func _nearest_friendly_dist(sds: EntityState) -> float:
	var rem: Dictionary = _wv.remotes_at(_elapsed)
	var best := -1.0
	for rid in rem:
		var e: EntityState = rem[rid]
		if not e.alive or e.is_downed or e.team != sds.team:
			continue
		var d: float = sds.pos.distance_to(e.pos)
		if best < 0.0 or d < best:
			best = d
	return best

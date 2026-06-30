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
var _downed_frozen_secs := -1.0   # latched bleed-out secs-left at the moment a bandage halted it (-1 = not halted)
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
var _build_ctrl: BuildController       # M12: build-tool state (build mode / selected piece / ghost yaw)
var _build_wheel := 0                  # pending wheel-cycle steps from _input (consumed each tick)
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
var _prev_point_owners: Array = []   # capture-point owners last broadcast; diffed for capture banners
var _piece_cat: PieceCatalog        # client mirror of the server piece catalog (for prediction collision)
var _struct_store: StructureStore   # client mirror of the server StructureStore; feeds prediction wall collision
var _auto_deploy_ref: int = -1    # --deploy=N arg; -1 = not set
var _auto_deploy_sent := false    # only send once
var _flash_test := false          # --flash-test: force the flashbang white-out on (visual QA)
var _suppress_test := false        # --suppress-test: force the suppression screen FX on (visual QA)
var _suppress_qa_on := true         # in suppress-test, gates the forced FX (A/B screenshot sequence flips it)
var _armor_demo := false            # --armor-demo: pin 3 armor-tier dummy soldiers in front of the camera
var _boom_test := false             # --boom-test: pump frag explosions in front of the camera (visual QA)
var _vehicle_test := false          # --vehicle-test: blow up a transport in front of the camera (visual QA)
var _impact_test := false           # --impact-test: pump bullet impacts in front of the camera (visual QA)
var _corpse_test := false           # --corpse-test: lay a few corpses in front of the camera (visual QA)
var _footstep_test := false         # --footstep-test: pump footstep dust in front of the camera (visual QA)
var _swing_test := false            # --swing-test: hold the viewmodel mid-swing for a visual QA shot
var _recoil_test := false           # --recoil-test: hold the viewmodel mid-recoil-kick for a visual QA shot
var _crosshair_test := false        # --crosshair-test: force a bloomed crosshair for a visual QA shot
var _ads_test := false              # --ads-test: force aim-down-sights on for a visual QA shot
var _scope_test := false            # --scope-test: force ADS + the sniper scope overlay for a visual QA shot
var _casing_test := false          # --casing-test: pump ejected shell casings for a visual QA shot
var _climb_test := false           # --climb-test: pin a climbing-posed dummy beside an upright one
var _jump_test := false            # --jump-test: pin an airborne-posed dummy beside an upright one
var _land_test := false            # --land-test: pump landing dust + viewmodel dip
var _downed_test := false          # --downed-test: force the DBNO overlay (bandage prompt/stabilized)
var _firepose_test := false        # --firepose-test: pin a fire-recoil-posed dummy beside an upright one
var _reloadpose_test := false      # --remote-reload-test: pin a reload-posed dummy beside an upright one
var _meleepose_test := false       # --remote-melee-test: pin a melee-lunge-posed dummy beside an upright one
var _glbshoot_test := false        # --glbshoot-test: GLB hold vs holding-both-shoot clip A/B
var _ads_t := 0.0                   # 0..1 eased aim-down-sights blend (client-only visual zoom/pose)
const ADS_RATE := 16.0              # ADS ease speed (per second); ~1/e in ~60 ms
var _prev_grounded := true          # for the local landing viewmodel dip (airborne->grounded edge)
var _prev_vy := 0.0                 # local vertical velocity from the previous frame (fall impact speed)
const LAND_VY := 3.5                # min downward speed (m/s) for a landing to kick the viewmodel dip
const ENGINE_AUDIO_RANGE := 200.0  # m: voice the engine of the nearest running vehicle within this
var _engine_test := false          # --engine-test: force the engine loop on (audio QA, no vehicle needed)
var _sprint_test := false           # --sprint-test: freeze the viewmodel sprint-lowered for a visual QA shot
var _reload_test := false           # --reload-test: freeze the viewmodel mid-reload for a visual QA shot
var _whiz_test := false             # --whiz-test: pump synthetic near-miss rounds across the view (crack/whiz QA)
var _smoke_test := false            # --smoke-test: pop a smoke cloud in front of the camera (visual QA)
var _grenade_test := false          # --grenade-test: lob cosmetic grenades across the view (visual QA)
var _gadget_test := false           # --gadget-test: place sample deployed gadgets in view (visual QA)
var _gadget_bytes := PackedByteArray()   # last GADGET_LIST bytes — skip the rebuild on an unchanged heartbeat
var _support_bytes := PackedByteArray()  # last SUPPORT_LIST bytes — skip the rebuild on an unchanged heartbeat
var _fob_bytes := PackedByteArray()      # last FOB_LIST bytes — skip rework on an unchanged heartbeat
var _team_fobs: Array = []               # M12-P3: own-team FOBs {squad, under_construction, enabled} for deploy
var _revive_marker_test := false    # --revive-marker-test: downed friendly + revive marker (visual QA)
var _support_test := false           # --support-test: support beam + aura between two soldiers (visual QA)
var _buildsite_test := false         # --buildsite-test: ghost build site (in-progress shovel construction)
var _fob_menu_test := false          # --fob-menu-test: seed a fake enabled FOB so the deploy screen shows it
var _build_test := false             # --build-test: auto-enter build mode (placement ghost) for a QA shot
var _build_test_done := false
var _build_test_arm := -1.0          # _elapsed when build-test entered build mode (drives the auto-place)
var _build_test_placed := false      # build-test sends one BUILD_REQUEST after a short delay
var _grenade_danger_test := false   # --grenade-danger-test: pin a live grenade near the player (visual QA)
var _capture_test := false          # --capture-test: pump capture-announcement banners (visual QA)
var _capture_test_next := 0.0
var _killfeed_test := false         # --killfeed-test: pump named killfeed entries + a fake roster (visual QA)
var _killfeed_test_next := 0.0
var _destroy_test := false          # --destroy-test: pump piece destruction debris/dust (visual QA)
var _collapse_test := false         # --collapse-test: play a building collapse cinematic (visual QA)
var _whiz_t := 0.0                  # --whiz-test cadence timer
var _whiz_i := 0                    # --whiz-test alternates crack/whiz offsets
var _active_slot := 0               # client-tracked weapon slot (0=primary/1=secondary) for quick-swap toggle
var _shot_after := -1.0           # --shot-after=N: auto-save a screenshot N secs after launch, then quit
var _shot_done := false
var _shot_count := 0              # makes auto-screenshot filenames unique within the same second
var _dbg_accum := 0.0             # 1 Hz input/deploy diagnostic accumulator
var _ch_fire_bloom := 0.0        # crosshair fire-spread (px); kicked per shot, decays each frame
var _novsync := false             # --novsync: disable vsync (perf diagnostic)
var _map_path: String = MAP_PATH  # --map=<name> overrides (must match server + bots)

# ---- C3 state ---------------------------------------------------------------
var _throwables: Array = []        # latest throwable list from SELF_STATE
var _being_revived: bool = false   # latest "a teammate is reviving me" flag from SELF_STATE
var _suppression: float = 0.0      # latest own-suppression scalar from SELF_STATE (M5.5-P2; M7 screen FX)
var _blind_ticks: int = 0          # latest remaining flashbang-blind ticks from SELF_STATE (M5.5-P3 white-out)
var _bandage_count: int = 0        # latest self-bandage charges from SELF_STATE (DBNO self-bandage UI)
var _bleed_halted: bool = false    # latest bleed-halted flag from SELF_STATE (downed: bandaged = stabilized)
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
	_armor_demo = args.has("armor-demo")            # visual QA: pin LIGHT/MEDIUM/HEAVY dummies in view
	_boom_test = args.has("boom-test")              # visual QA: pump frag explosions in front of camera
	_vehicle_test = args.has("vehicle-test")        # visual QA: blow up a transport in front of camera
	_impact_test = args.has("impact-test")          # visual QA: pump bullet impacts in front of camera
	_corpse_test = args.has("corpse-test")          # visual QA: lay corpses in front of camera
	_footstep_test = args.has("footstep-test")      # visual QA: pump footstep dust in front of camera
	_swing_test = args.has("swing-test")            # visual QA: hold the viewmodel mid-swing
	_recoil_test = args.has("recoil-test")          # visual QA: hold the viewmodel mid-recoil-kick
	_crosshair_test = args.has("crosshair-test")    # visual QA: force a bloomed crosshair
	_ads_test = args.has("ads-test")                # visual QA: force aim-down-sights on
	_scope_test = args.has("scope-test")            # visual QA: force ADS + the sniper scope overlay
	_casing_test = args.has("casing-test")          # visual QA: pump ejected shell casings
	_climb_test = args.has("climb-test")            # visual QA: climbing pose vs upright dummy
	_jump_test = args.has("jump-test")              # visual QA: airborne pose vs upright dummy
	_land_test = args.has("land-test")              # visual QA: landing dust + viewmodel dip
	_downed_test = args.has("downed-test")          # visual QA: force the DBNO bandage overlay
	_firepose_test = args.has("firepose-test")      # visual QA: fire-recoil pose vs upright dummy
	_reloadpose_test = args.has("remote-reload-test")  # visual QA: reload pose vs upright dummy
	_meleepose_test = args.has("remote-melee-test")    # visual QA: melee lunge pose vs upright dummy
	_glbshoot_test = args.has("glbshoot-test")      # visual QA: GLB hold vs holding-both-shoot clip
	_engine_test = args.has("engine-test")          # audio QA: force the vehicle engine loop on
	_sprint_test = args.has("sprint-test")          # visual QA: freeze the viewmodel sprint-lowered
	_reload_test = args.has("reload-test")          # visual QA: freeze the viewmodel mid-reload
	_whiz_test = args.has("whiz-test")              # audio+visual QA: synthetic near-miss crack/whiz rounds
	_smoke_test = args.has("smoke-test")            # visual QA: pop a smoke cloud in front of the camera
	_grenade_test = args.has("grenade-test")        # visual QA: lob cosmetic grenades across the view
	_gadget_test = args.has("gadget-test")          # visual QA: place sample deployed gadgets in view
	_revive_marker_test = args.has("revive-marker-test")   # visual QA: downed friendly + revive marker
	_support_test = args.has("support-test")        # visual QA: support beam + aura between two soldiers
	_buildsite_test = args.has("buildsite-test")    # visual QA: ghost build site (shovel construction)
	_fob_menu_test = args.has("fob-menu-test")      # visual QA: deploy screen with a Squad FOB option
	_build_test = args.has("build-test")            # visual QA: auto-enter build mode (placement ghost)
	_grenade_danger_test = args.has("grenade-danger-test") # visual QA: pin a live grenade near the player
	_capture_test = args.has("capture-test")        # visual QA: pump capture-announcement banners
	_killfeed_test = args.has("killfeed-test")      # visual QA: pump named killfeed entries
	_destroy_test = args.has("destroy-test")        # visual QA: pump piece destruction debris/dust
	_collapse_test = args.has("collapse-test")      # visual QA: play a building collapse cinematic
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
		_pred.set_geometry(_map.ladders, _map.platforms)   # so climb/platform predict like the server
	# Client mirror of the server's piece catalog, so prediction can collide with structures (walls).
	# Built from STRUCTURE_BASELINE/DELTA; without it the client predicts through walls and rubber-bands.
	_piece_cat = PieceCatalog.load_file("res://pieces/pieces.json")
	_build_ctrl = BuildController.new(_piece_cat)   # M12: build-tool state machine
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
		elif _in_vehicle() >= 0:
			# Slaved to the vehicle server-side: predicting free movement only rubber-bands the eye.
			# Zero movement + movement buttons (keep look + fire) and snap the predicted pawn onto the
			# authoritative vehicle-seat position so the POV rides along instead of drifting/bouncing.
			cmd["move_x"] = 0.0
			cmd["move_y"] = 0.0
			cmd["buttons"] = int(cmd["buttons"]) & InputCommand.BTN_FIRE
			_pred.predicted.pos = ss.pos
			_pred.predicted.velocity = Vector3.ZERO
		# M12 build tool: while build mode is active, the player never shoots/reloads — fire becomes
		# place/shovel and reload becomes rotate. Mask those bits and set BTN_SHOVEL when holding the
		# build tool on an under-construction site (the server advances it). Place/rotate/cycle are
		# handled at render rate in _process; here we only shape the authoritative input bits.
		if _build_ctrl != null and _build_ctrl.active:
			if ss == null or not ss.alive or ss.is_downed or _in_vehicle() >= 0:
				_build_ctrl.set_active(false)   # build mode never survives death/downed/entering a vehicle
			else:
				var bb := int(cmd["buttons"]) & ~(InputCommand.BTN_FIRE | InputCommand.BTN_RELOAD)
				var beye := _pred.predicted.eye_position()
				var bfwd := Combat._forward(wrapf(float(cmd["yaw"]) + PI, -PI, PI), float(cmd["pitch"]))
				var bcell := _build_ctrl.aimed_cell(beye, bfwd)
				if _build_ctrl.action_at(bcell, _wv.structures(), beye) == BuildController.SHOVEL \
						and (Input.is_action_pressed("fire") or _build_test):
					bb |= InputCommand.BTN_SHOVEL   # _build_test forces the shovel so the QA shot shows it rise
				cmd["buttons"] = bb
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
			_renderer.play_viewmodel_recoil(_elapsed)   # kick the viewmodel on each shot
			if _wpred.weapon != Weapon.RPG:
				_renderer.eject_casing(_elapsed)   # brass flies from the port (no casing for the launcher)
			_ch_fire_bloom = minf(_ch_fire_bloom + 3.0, 14.0)   # bloom the crosshair on each shot
			if _audio != null:
				_audio.play_at(_fire_event_for(_wpred.weapon), _pred.predicted.eye_position())

		if buttons & InputCommand.BTN_RELOAD:
			var _was_reloading: bool = _wpred.reloading
			_wpred.begin_reload(_client_tick)
			if not _was_reloading and _wpred.reloading:
				# Reload-start transition: play the reload viewmodel anim over the real reload time + sfx.
				if _renderer != null:
					_renderer.play_viewmodel_reload(_elapsed, _wpred.reload_remaining(_client_tick) * SimLoop.DT)
				if _audio != null:
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
			"view_server_tick": _wv.view_tick(_elapsed),   # rendered-time tick (now-DELAY) for lag-comp rewind
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

# ---- debug perf overlay toggle (F3) -----------------------------------------
# F3 hides/shows the green fps/draws/vram readout. Default on (preserves the dev workflow); hiding it
# gives a clean HUD for normal play / screenshots without entering free-fly photo mode (F8). Edge-
# detected like the screenshot key (the HUD can swallow the event, so poll in _process).
var _perf_overlay_on := true
var _perf_key_down := false

func _poll_debug_overlay_key() -> void:
	var down := Input.is_physical_key_pressed(KEY_F3)
	if down and not _perf_key_down:
		_perf_overlay_on = not _perf_overlay_on
		if _hud_view != null:
			_hud_view.set_perf_visible(_perf_overlay_on)
		print("[debug] perf overlay = %s" % _perf_overlay_on)
	_perf_key_down = down

func _save_screenshot() -> void:
	var tex := get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		push_warning("[shot] could not grab viewport image")
		return
	var dir := "%s/bf-shots" % OS.get_environment("HOME")
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace("T", "_").replace(":", "-")
	_shot_count += 1
	var path := "%s/shot_%s_%02d.png" % [dir, stamp, _shot_count]
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
	_poll_debug_overlay_key()   # F3 toggles the green perf/debug overlay
	# --shot-after=N: automated visual QA — save one screenshot N secs after launch, then quit.
	if _shot_after >= 0.0 and not _shot_done and _scene_built and _elapsed >= _shot_after:
		_shot_done = true
		if _suppress_test:
			# A/B from the SAME camera: a clean frame (FX off), then the suppressed frame (FX on).
			_suppress_qa_on = false
			get_tree().create_timer(0.15).timeout.connect(func() -> void:
				_save_screenshot()             # 1: clean
				_suppress_qa_on = true
				get_tree().create_timer(0.6).timeout.connect(func() -> void:
					_save_screenshot()         # 2: suppressed
					get_tree().create_timer(0.4).timeout.connect(func() -> void: get_tree().quit())))
		else:
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
	# Aim-down-sights (client-only visual zoom/pose). Held right-mouse ("aim") while deployed, not
	# sprinting, not in a vehicle, menu closed. Eased so the zoom/pose glide rather than snap.
	var weapon0: int = _wpred.weapon if _wpred != null else Weapon.AR
	var ads_want: bool = (deployed0 and not menu_open0 and _in_vehicle() < 0 \
		and not Input.is_action_pressed("sprint") \
		and (_ads_test or _scope_test or Input.is_action_pressed("aim")))
	_ads_t = lerpf(_ads_t, 1.0 if ads_want else 0.0, clampf(_dt * ADS_RATE, 0.0, 1.0))
	# Local landing dip: on the predicted pawn's airborne->grounded edge after a real fall, kick the
	# viewmodel down (scaled by impact speed). _prev_vy holds the falling speed from the prior frame.
	var lg: bool = _pred.predicted.grounded
	if lg and not _prev_grounded and _prev_vy < -LAND_VY and _renderer != null:
		_renderer.play_land_dip(clampf((-_prev_vy - LAND_VY) / 8.0, 0.2, 1.0))
	_prev_grounded = lg
	_prev_vy = _pred.predicted.velocity.y
	if deployed0 and not menu_open0:
		# Slow the look in proportion to the zoom so on-screen aim speed stays ~constant (zoom sensitivity).
		var look_scale: float = lerpf(1.0, _ads_fov(weapon0) / _settings.fov, _ads_t)
		_input_ctrl.update_look(_settings, look_scale)   # apply accumulated mouse delta at render rate
	else:
		_input_ctrl.drain_look()
	_pos_err = _pos_err.lerp(Vector3.ZERO, clampf(_dt * RECON_SMOOTH, 0.0, 1.0))
	var eye: Vector3 = _prev_eye.lerp(_curr_eye, Engine.get_physics_interpolation_fraction()) + _pos_err

	if _audio != null:
		_audio.set_listener_pos(eye)   # spatial-audio listener tracks the rendered camera/eye
		# Engine loop: voice the nearest running vehicle (driver seated, or the one we're riding).
		if _engine_test:
			_audio.update_engine(eye + Vector3(3, 0, 0))   # QA: force the engine loop just to our right
		else:
			var eng: Dictionary = EngineAudio.nearest_running(_wv.vehicles(), eye, _in_vehicle(), ENGINE_AUDIO_RANGE)
			if bool(eng["found"]):
				_audio.update_engine(eng["pos"])
			else:
				_audio.stop_engine()

	if _whiz_test and _camera != null and _audio != null:
		# QA: a synthetic round sweeps left->right just above the eye. The tracer is re-emitted every
		# frame (its TTL is ~1 frame) so a streak is always on screen for a screenshot; the crack/whiz
		# audio + log fire on a ~0.6 s cadence, alternating a 1 m (crack) and 2.5 m (whiz) near miss.
		var basis := _camera.global_transform.basis
		var fwd := -basis.z
		var off := 1.0 if _whiz_i % 2 == 0 else 2.5
		var cross := eye + basis.x * off                  # closest-approach point: `off` m to the right of the eye
		var origin := cross + fwd * 40.0                  # round starts 40 m downrange (ahead)
		var dir := -fwd                                   # flying back toward (and past) the player
		if _renderer != null:
			_renderer.tracer_from(origin, dir, _elapsed)  # every frame: always a visible streak for QA
		_whiz_t += _dt
		if _whiz_t >= 0.6:
			_whiz_t = 0.0
			_whiz_i += 1
			var pb: Dictionary = BulletPassby.classify(origin, dir, eye)
			if pb["kind"] != "":
				_audio.play_at(pb["kind"], pb["point"])
			print("[whiz-test] off=%.1f kind=%s" % [off, pb["kind"]])

	if _wpred != null and not _photo_mode:
		_renderer.set_viewmodel_weapon(_wpred.weapon)   # show the RPG launcher etc., not always the AR
	_renderer.set_ads(_ads_t)   # viewmodel sight pose + bob damping (before update -> _pose_viewmodel reads it)
	# Hide the gun while scoped (you look through the scope, not at the centred gun).
	_renderer.set_viewmodel_scope_hidden((_scope_test or _is_scoped(weapon0)) and _ads_t > 0.6)
	var cam_fov: float = lerpf(_settings.fov, _ads_fov(weapon0), _ads_t)   # FOV zoom toward the per-weapon ADS FOV
	var _t0 := Time.get_ticks_usec()
	_renderer.update(_wv, _pred, _elapsed, cam_fov, _input_ctrl.yaw, _input_ctrl.pitch, eye, _dt)
	if _photo_mode:
		_fly_photo_camera(_dt)   # override the pawn-eye camera with the free-fly position
	var _t1 := Time.get_ticks_usec()

	var ctx: Dictionary = {
		"weapon_predictor": _wpred,
		"tick": _client_tick,
		"self_pos": _pred.predicted.pos,
		"self_eye": _pred.predicted.eye_position(),
		"self_yaw": _input_ctrl.yaw,   # client look yaw (camera), not the reconciled pawn yaw
		"grenades": _grenade_danger_sources(),
		"in_vehicle": _in_vehicle(),
		"objectives": _objectives(),
		"match_state": _match_state,
		"point_positions": _point_positions(),
		"capture_radius": 8.0,
		"now": _elapsed,
		# C3 additions
		"roster": _killfeed_test_roster() if _killfeed_test else _wv.roster(),
		"self_id": 1 if _killfeed_test else my_id,
		"entities": _build_entities(),
		"throwables": _throwables,
		"downed_mates": _downed_mates(),
		"vehicles_near": _vehicles_near(),
	}
	if _capture_test and _elapsed >= _capture_test_next:   # visual QA: keep one of each banner fresh
		_capture_test_next = _elapsed + 2.0
		_hud_model.push_capture_events([
			{"label": "A", "status": CaptureAnnounce.FRIENDLY},
			{"label": "B", "status": CaptureAnnounce.HOSTILE},
			{"label": "C", "status": CaptureAnnounce.NEUTRAL}], _elapsed)
	if _killfeed_test and _elapsed >= _killfeed_test_next:   # visual QA: keep named kills fresh
		_killfeed_test_next = _elapsed + 2.0
		_hud_model.push_kill({"killer": 1, "victim": 2, "headshot": true, "weapon": 0}, _elapsed)
		_hud_model.push_kill({"killer": 3, "victim": 4, "headshot": false, "weapon": 0}, _elapsed)
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
			_downed_frozen_secs = -1.0
		if Input.is_action_pressed("jump"):
			_giveup_hold += _dt
			if _giveup_hold >= GIVEUP_HOLD and not _giveup_sent and _peer != null:
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL, Protocol.encode_give_up(), ENetPacketPeer.FLAG_RELIABLE)
				_giveup_sent = true
		else:
			_giveup_hold = 0.0
		var secs_left: float = maxf(0.0, BLEEDOUT_SECS - (_elapsed - _downed_since))
		# Once the server reports bleed halted (bandaged), latch the time-left so the UI stops counting.
		if _bleed_halted and _downed_frozen_secs < 0.0:
			_downed_frozen_secs = secs_left
		var shown_secs: float = _downed_frozen_secs if _bleed_halted else secs_left
		_hud_view.set_downed(true, shown_secs, _nearest_friendly_dist(sds), clampf(_giveup_hold / GIVEUP_HOLD, 0.0, 1.0), _being_revived, _bandage_count, _bleed_halted)
	elif _downed_test:
		# Visual QA: force the DBNO overlay, alternating the bleeding/bandage-prompt and stabilized states.
		var halted := fmod(_elapsed, 6.0) > 3.0
		_hud_view.set_downed(true, 6.0, 12.0, 0.0, false, 3, halted)
	elif _downed_since >= 0.0:
		_downed_since = -1.0
		_downed_frozen_secs = -1.0
		_hud_view.set_downed(false, 0.0, -1.0, 0.0)

	# ---- C3: scoreboard hold (TAB) ------------------------------------------------
	if _hud_view != null:
		_hud_view.set_scoreboard_held(Input.is_action_pressed("scoreboard"))
		# Hide the alive-only combat HUD (ammo + throwable selector) while downed/dead/deploying.
		var hs: EntityState = _wv.self_state()
		var ch_alive: bool = hs != null and hs.alive and not hs.is_downed
		_hud_view.set_alive_hud(ch_alive)
		# Dynamic crosshair spread — honest client-side bloom from movement / airborne / stance / fire.
		_ch_fire_bloom = maxf(0.0, _ch_fire_bloom - 24.0 * _dt)
		var cvel: Vector3 = _pred.predicted.velocity
		var cspeed: float = Vector2(cvel.x, cvel.z).length()
		var cspread: float = clampf(cspeed / 6.0, 0.0, 1.0) * 14.0
		if not _pred.predicted.grounded:
			cspread += 18.0
		match _pred.predicted.stance:
			Stance.CROUCH: cspread *= 0.55
			Stance.PRONE: cspread *= 0.35
		cspread += _ch_fire_bloom
		if _crosshair_test:
			cspread = 22.0   # visual QA: force a clearly-bloomed reticle for a screenshot
		# Hide the hip crosshair once aiming down sights — the sights (or scope reticle) take over.
		_hud_view.update_crosshair(cspread, (not ch_alive and not _crosshair_test) or _ads_t > 0.5)
		# Sniper scope overlay: only for a scoped weapon (DMR), scaled by the ADS blend. --scope-test forces it.
		_hud_view.set_scope(_ads_t if (_scope_test or _is_scoped(weapon0)) else 0.0)
		# M5.5-P3 flashbang white-out from the SELF_STATE blind byte (cleared on death/deploy).
		# --flash-test forces a strong-but-translucent veil so the world shows through (visual QA);
		# it still routes through blind_intensity so the real render chain is exercised.
		var blinded := hs != null and hs.alive and not hs.is_downed
		var blind_ticks := 34 if _flash_test else (_blind_ticks if blinded else 0)
		_hud_view.set_blind(HudModel.blind_intensity(blind_ticks))
		# M5.5-P2 suppression screen FX from the SELF_STATE suppression byte (same gating as blind:
		# only while alive + not downed). --suppress-test forces a strong veil for visual QA.
		var supp := (0.8 if _suppress_qa_on else 0.0) if _suppress_test else (_suppression if blinded else 0.0)
		_hud_view.set_suppression(HudModel.suppression_intensity(supp))

	# ---- C3: revive intent (no self-recovery — a teammate must revive you, BattleBit-style) ----
	var sss: EntityState = _wv.self_state()
	var is_downed: bool = sss != null and sss.alive and sss.is_downed
	if is_downed:
		# Self-bandage (R): spend a bandage to halt the bleed-out (no self-revive — a teammate must
		# revive you, BattleBit-style). Server gates (must be downed, have a charge, not already halted).
		if Input.is_action_just_pressed("reload") and _bandage_count > 0 and not _bleed_halted and _peer != null:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL, Protocol.encode_self_bandage(), ENetPacketPeer.FLAG_RELIABLE)
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
		# Exit-vehicle intent: a single F press while seated (the prompt switched to "exit_vehicle").
		if ip != null and String(ip.get("action", "")) == "exit_vehicle" \
				and Input.is_action_just_pressed("interact") and _peer != null:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_vehicle_action(Protocol.VA_EXIT, int(ip["target"]), 0),
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
		# Build tool out = no combat: while build mode is active (or a menu is open) the combat
		# one-shots below are locked, so a place-click / habitual keypress can't also fire, throw,
		# melee, detonate, or change fire mode.
		var building: bool = _build_ctrl != null and _build_ctrl.active
		var combat_locked: bool = building or menu_open0

		# Throwable cycle
		if Input.is_action_just_pressed("throwable_cycle") and not combat_locked:
			_hud_model.cycle_throwable(_throwables.size())

		# Fire-mode select (V): cycle the predicted mode + tell the server so its gating matches.
		if Input.is_action_just_pressed("fire_select") and not combat_locked:
			var new_mode: int = _wpred.cycle_fire_mode()
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_set_fire_mode(new_mode), ENetPacketPeer.FLAG_RELIABLE)

		# Quick melee (C): send the swing + play the viewmodel swing. Server resolves the hit.
		if Input.is_action_just_pressed("melee") and not combat_locked:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL, Protocol.encode_melee(), ENetPacketPeer.FLAG_RELIABLE)
			if _renderer != null:
				_renderer.play_viewmodel_swing(_elapsed)
			if _audio != null:
				_audio.play_2d("melee")   # own swing whoosh (was a dead catalog entry); hit-confirm stays the hitmarker

		# Quick-swap primary/secondary (mouse wheel): toggle the slot; the swap anim plays when the
		# weapon actually changes (SELF_STATE → set_viewmodel_weapon), so client and server stay in step.
		# Suppressed in build mode, where the wheel cycles the selected piece instead.
		if Input.is_action_just_pressed("swap_weapon") and not _build_ctrl.active:
			_active_slot = 1 - _active_slot
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_swap_weapon(_active_slot), ENetPacketPeer.FLAG_RELIABLE)

		# M12 build tool (T toggles): in build mode the wheel cycles the piece, reload rotates it 90°,
		# and a fire click on a valid empty cell places it (BUILD_REQUEST, or PLACE_FOB for a leader's
		# FOB). The held-shovel + fire/reload suppression happen in _physics_process.
		if _build_test and not _build_test_done:
			_build_test_done = true
			_build_ctrl.set_active(true)   # QA: drop straight into build mode for a placement-ghost shot
			_build_test_arm = _elapsed
			_input_ctrl.pitch = -0.42      # look down at nearby ground so the ghost is within build range
		if Input.is_action_just_pressed("build_mode") and not menu_open0:
			_build_ctrl.toggle()
		if _build_ctrl.active and not menu_open0:
			var is_leader := _is_squad_leader(sss.team)
			# Apply every accumulated wheel notch (one cycle step each), preserving net direction.
			while _build_wheel != 0:
				var step := signi(_build_wheel)
				_build_ctrl.cycle(step, is_leader)
				_build_wheel -= step
			if Input.is_action_just_pressed("reload"):
				_build_ctrl.rotate()
			var btype := _build_ctrl.current_type(is_leader)
			var beye := _pred.predicted.eye_position()
			var bfwd := Combat._forward(wrapf(_input_ctrl.yaw + PI, -PI, PI), _input_ctrl.pitch)
			var bcell := _build_ctrl.aimed_cell(beye, bfwd)
			var act := _build_ctrl.action_at(bcell, _wv.structures(), beye)
			if btype >= 0:   # empty/invalid cycle -> no place/preview (defensive; the catalog always has fortifications)
				# QA: auto-place one piece ~1.5 s after entering build mode (proves the place round-trip;
				# the forced shovel in _physics_process then builds it up for the screenshot).
				if _build_test and not _build_test_placed and _build_test_arm >= 0.0 \
						and _elapsed - _build_test_arm > 1.5 and act == BuildController.PLACE:
					_build_test_placed = true
					_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
						Protocol.encode_build_request(btype, bcell, _build_ctrl.yaw), ENetPacketPeer.FLAG_RELIABLE)
				if act == BuildController.PLACE and Input.is_action_just_pressed("fire"):
					if _build_ctrl.current_is_fob(is_leader):
						_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
							Protocol.encode_place_fob(bcell, _build_ctrl.yaw), ENetPacketPeer.FLAG_RELIABLE)
					else:
						_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
							Protocol.encode_build_request(btype, bcell, _build_ctrl.yaw), ENetPacketPeer.FLAG_RELIABLE)
				var piece_name := _piece_cat.name_of(btype)
				if _renderer != null:
					_renderer.set_build_preview(true, piece_name, bcell, _build_ctrl.yaw,
						act == BuildController.PLACE)
				if _hud_view != null:
					var verb := "shovel" if act == BuildController.SHOVEL else "place"
					_hud_view.set_build_hint("BUILD: %s  ·  wheel cycle  ·  R rotate  ·  LMB %s  ·  T exit"
						% [piece_name.to_upper(), verb])
		else:
			_build_wheel = 0   # preview + hint are cleared by the inactive-state tail block in _process

		# Throw: send grenade or RPG based on active throwable kind
		if Input.is_action_just_pressed("throw") and not combat_locked:
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
					if _renderer != null:
						# Instant thrower feedback: a cosmetic grenade arcs along the shared Grenade
						# model from the eye (matching the server) and vanishes on landing / at the fuse.
						_renderer.throw_grenade(_pred.predicted.eye_position(),
							Grenade.launch_velocity(aim_dir), kind, _elapsed)
				elif kind == 100:  # RPG
					_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
						Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE,
							_pred.predicted.pos, aim_dir, 0), ENetPacketPeer.FLAG_RELIABLE)

		# Left-click also fires the RPG when it's the equipped weapon. The RPG isn't a hit-scan
		# click weapon, so without this the primary-fire button feels dead for an RPG loadout.
		if Input.is_action_just_pressed("fire") and _has_rpg_equipped() and not combat_locked:
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
		if Input.is_action_just_pressed("gadget") and not combat_locked:
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

	# M12: hide the build-tool ghost + hint and drop any pending wheel whenever build mode isn't
	# actively interactive — inactive, a menu is open, or the player isn't alive (covers the 1-frame
	# gap before _physics_process force-clears build mode on death). The active path drives the
	# preview itself above.
	if _build_ctrl != null:
		var bss: EntityState = _wv.self_state()
		var build_live: bool = _build_ctrl.active and not menu_open0 and bss != null and bss.alive
		if not build_live:
			_build_wheel = 0
			if _renderer != null:
				_renderer.set_build_preview(false, "", Vector3i.ZERO, 0, false)
			if _hud_view != null:
				_hud_view.set_build_hint("")

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
			_rebuild_struct_store(bytes)   # keep the prediction-collision store in sync
		Protocol.Msg.STRUCTURE_DELTA:
			_wv.apply_structure_delta(bytes)
			_apply_struct_delta_to_store(bytes)
		Protocol.Msg.COLLAPSE:
			var _bid := Protocol.decode_collapse(bytes)
			_collapse_struct_store(_bid)
			_wv.apply_collapse(_bid)
		Protocol.Msg.SHOT_FX:
			var fx: Dictionary = Protocol.decode_shot_fx(bytes)
			if _renderer != null:
				_renderer.tracer_from(fx["origin"], fx["dir"], _elapsed)
				_renderer.eject_casing_at(fx["origin"], fx["dir"], _elapsed)   # remote shooter's brass
				_renderer.flash_fire(int(fx.get("shooter_id", 0)), _elapsed)   # remote body fire-recoil twitch
			if _audio != null:
				_audio.play_at("gunfire", fx["origin"])   # spatial remote-pawn gunfire
				# Supersonic near-miss: if this remote round passes close to us, snap a crack/whiz
				# at its closest approach (view-only — server already resolved the shot).
				if _pred != null and _pred.predicted != null:
					var pb: Dictionary = BulletPassby.classify(fx["origin"], fx["dir"], _pred.predicted.eye_position())
					if pb["kind"] != "":
						_audio.play_at(pb["kind"], pb["point"])
		Protocol.Msg.RELOAD_FX:
			var rl: Dictionary = Protocol.decode_reload_fx(bytes)
			if _renderer != null:
				# duration is in sim ticks; the pose holds for that wall-clock span.
				_renderer.remote_reload(int(rl["reloader_id"]), _elapsed, float(rl["duration_ticks"]) * SimLoop.DT)
		Protocol.Msg.MELEE_FX:
			var ml: Dictionary = Protocol.decode_melee_fx(bytes)
			if _renderer != null:
				_renderer.remote_melee(int(ml["melee_id"]), _elapsed)   # remote swing/lunge pose
		Protocol.Msg.ROCKET_FX:
			var rfx: Dictionary = Protocol.decode_rocket_fx(bytes)
			if _renderer != null:
				_renderer.fire_rocket(rfx["origin"], rfx["dir"], _elapsed)   # remote rocket flies + launch flash
		Protocol.Msg.GRENADE_FX:
			var gfx: Dictionary = Protocol.decode_grenade_fx(bytes)
			if _renderer != null:
				# Remote pawn's thrown grenade arcs the shared Grenade model (same as the local thrower).
				_renderer.throw_grenade(gfx["origin"], Grenade.launch_velocity(gfx["dir"]), int(gfx["kind"]), _elapsed)
		Protocol.Msg.GADGET_LIST:
			if bytes != _gadget_bytes:
				_gadget_bytes = bytes   # skip the rebuild on an unchanged 1 Hz heartbeat
				if _renderer != null:
					_renderer.set_gadgets(Protocol.decode_gadget_list(bytes))
		Protocol.Msg.SUPPORT_LIST:
			if bytes != _support_bytes:
				_support_bytes = bytes   # skip the rebuild on an unchanged 1 Hz heartbeat
				if _renderer != null:
					_renderer.set_support_links(Protocol.decode_support_list(bytes))
		Protocol.Msg.FOB_LIST:
			# M12-P3: the team's FOBs (squad/under_construction/enabled). Refresh the deploy menu when
			# the set changes so an enabled squad FOB appears (or vanishes) as a spawn option.
			if bytes != _fob_bytes:
				_fob_bytes = bytes   # skip rework on the unchanged 1 Hz heartbeat
				_team_fobs = Protocol.decode_fob_list(bytes)
				_deploy_menu_populated = false   # re-enumerate spawns with the new FOB set
		Protocol.Msg.DETONATION:
			var det: Dictionary = Protocol.decode_detonation(bytes)
			if _renderer != null:
				_renderer.spawn_explosion(det["pos"], int(det["kind"]), _elapsed)
			if _audio != null:
				# Flashbang has its own bright-pop cue (was a dead catalog entry — every detonation
				# played the frag "explosion" boom regardless of kind).
				var snd := "flashbang" if int(det["kind"]) == Protocol.DET_FLASH else "explosion"
				_audio.play_at(snd, det["pos"])   # spatial (synth tone until real asset)
		Protocol.Msg.VEHICLE_DESTROYED:
			# Reliable, sent to all clients on hp->0 (server _destroy_vehicle). The persistent burnt
			# hulk is driven by the replicated hp<=0 in the vehicle pool; this event adds the one-shot
			# fireball + blast audio at the vehicle's last known position (cosmetic, like DETONATION).
			var vd: Dictionary = Protocol.decode_vehicle_destroyed(bytes)
			var dvid: int = int(vd["vehicle_id"])
			var vehs: Dictionary = _wv.vehicles()
			if vehs.has(dvid):
				var vpos: Vector3 = (vehs[dvid] as VehicleState).pos
				if _renderer != null:
					_renderer.destroy_vehicle(dvid, vpos + Vector3(0, 1.0, 0), _elapsed)
				if _audio != null:
					_audio.play_at("explosion", vpos)
		Protocol.Msg.IMPACT_FX:
			var imp: Dictionary = Protocol.decode_impact_fx(bytes)
			if _renderer != null:
				_renderer.spawn_impact(imp["pos"], int(imp["kind"]), _elapsed)
		Protocol.Msg.SMOKE_DEPLOYED:
			var sm: Dictionary = Protocol.decode_smoke_deployed(bytes)
			if _renderer != null:
				# Lifetime from the server's absolute expiry tick vs our latest server tick (30 Hz);
				# clamp to a sane window, fall back to the 5 s server smoke duration if unknown.
				var dur := float(int(sm["expire_tick"]) - _last_server_tick) / 30.0
				if dur <= 0.5 or dur > 12.0:
					dur = 5.0
				_renderer.spawn_smoke(sm["pos"], float(int(sm["radius"])), dur, _elapsed)

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
					_build_vehicle_candidates(ss.team),
					_build_fob_candidates())
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
					_build_vehicle_candidates(ss.team),
					_build_fob_candidates())
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
	_bandage_count = int(d.get("bandage_count", 0))        # DBNO self-bandage charges
	_bleed_halted = bool(d.get("bleed_halted", false))     # downed: bleed-out halted by a bandage

# ---- MATCH_STATE ------------------------------------------------------------
func _handle_match_state(bytes: PackedByteArray) -> void:
	_match_state = Protocol.decode_match_state(bytes)
	# Mirror point ownership into local ConquestState so DeployMenu sees current owners
	var pts: Array = _match_state.get("points", [])
	for i in mini(pts.size(), _conquest.points.size()):
		_conquest.points[i]["owner"] = int(pts[i]["owner"])
	# Banner any ownership changes since the last broadcast (capture/lost/neutralized).
	var owners: Array = []
	for p: Dictionary in pts:
		owners.append(int(p["owner"]))
	if not _prev_point_owners.is_empty() and _hud_model != null and _map != null:
		var changes: Array = CaptureAnnounce.diff(_prev_point_owners, owners, _local_team())
		if not changes.is_empty():
			var events: Array = []
			for ch: Dictionary in changes:
				var idx: int = int(ch["index"])
				var label: String = String(_map.points[idx]["id"]) if idx < _map.points.size() else "?"
				events.append({"label": label, "status": int(ch["status"])})
			_hud_model.push_capture_events(events, _elapsed)
	_prev_point_owners = owners

## Local team from self-state (-1 until known) — used to colour capture banners friend/foe.
func _local_team() -> int:
	var ss: EntityState = _wv.self_state()
	return ss.team if ss != null else -1

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
	_renderer.armor_demo = _armor_demo   # --armor-demo: pin armor-tier dummies for a QA screenshot
	_renderer.boom_demo = _boom_test     # --boom-test: pump explosions for a QA screenshot
	_renderer.wreck_demo = _vehicle_test # --vehicle-test: blow up a transport for a QA screenshot
	_renderer.casing_demo = _casing_test # --casing-test: pump shell casings for a QA screenshot
	_renderer.climb_demo = _climb_test   # --climb-test: climbing-pose dummy for a QA screenshot
	_renderer.jump_demo = _jump_test     # --jump-test: airborne-pose dummy for a QA screenshot
	_renderer.land_demo = _land_test     # --land-test: landing dust + viewmodel dip for a QA screenshot
	_renderer.firepose_demo = _firepose_test  # --firepose-test: fire-recoil pose dummy for a QA screenshot
	_renderer.reloadpose_demo = _reloadpose_test  # --remote-reload-test: reload pose dummy for a QA screenshot
	_renderer.meleepose_demo = _meleepose_test  # --remote-melee-test: melee lunge pose dummy for a QA screenshot
	_renderer.glbshoot_demo = _glbshoot_test  # --glbshoot-test: GLB shoot-clip A/B for a QA screenshot
	_renderer.impact_demo = _impact_test # --impact-test: pump bullet impacts for a QA screenshot
	_renderer.corpse_demo = _corpse_test # --corpse-test: lay corpses for a QA screenshot
	_renderer.footstep_demo = _footstep_test # --footstep-test: pump footstep dust for a QA screenshot
	_renderer.smoke_demo = _smoke_test   # --smoke-test: pop a smoke cloud for a QA screenshot
	_renderer.grenade_demo = _grenade_test # --grenade-test: lob cosmetic grenades for a QA screenshot
	_renderer.gadget_demo = _gadget_test # --gadget-test: place sample gadgets for a QA screenshot
	_renderer.revive_demo = _revive_marker_test # --revive-marker-test: downed friendly + revive marker
	_renderer.support_demo = _support_test   # --support-test: support beam + aura between two soldiers
	_renderer.piece_catalog = _piece_cat     # M12: lets the renderer derive build-site fill fractions
	_renderer.buildsite_demo = _buildsite_test  # --buildsite-test: ghost in-progress shovel construction
	_renderer.destroy_demo = _destroy_test   # --destroy-test: pump piece destruction debris/dust
	_renderer.collapse_demo = _collapse_test # --collapse-test: play a building collapse cinematic
	_renderer.vm_swing_test = _swing_test # --swing-test: freeze the viewmodel mid-swing
	_renderer.vm_recoil_test = _recoil_test # --recoil-test: freeze the viewmodel mid-recoil-kick
	_renderer.vm_sprint_test = _sprint_test # --sprint-test: freeze the viewmodel sprint-lowered
	_renderer.vm_reload_test = _reload_test # --reload-test: freeze the viewmodel mid-reload

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
	# Route renderer footsteps (local + visible remotes) to the spatial audio bus.
	_renderer.footstep.connect(_on_footstep)
	# Route bullet impacts (real IMPACT_FX + the --impact-test demo) to a spatial thud.
	_renderer.impact.connect(_on_impact)

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

## A footfall fired by the renderer (local pawn or a visible remote) -> spatial footstep sound.
## Presentation-only (AGENTS.md §7); the AudioDirector handles distance falloff + voice priority.
func _on_footstep(world_pos: Vector3, _intensity: float) -> void:
	if _audio != null:
		_audio.play_at("footstep", world_pos)

## A bullet terminated in the world — play a spatial thud where it landed (wall/dirt; flesh is
## silent, it gets a blood puff instead). Presentation-only (AGENTS.md §7).
func _on_impact(world_pos: Vector3, kind: int) -> void:
	if _audio == null:
		return
	var snd := ImpactAudio.sound_for(kind)
	if snd != "":
		_audio.play_at(snd, world_pos)

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

## Fake roster for --killfeed-test so synthetic kills resolve to names + friend/foe (self_id is 1 -> team 0).
func _killfeed_test_roster() -> Array:
	return [{"id": 1, "name": "Vanguard", "team": 0, "squad": 0, "score": 0},
		{"id": 2, "name": "Reaper", "team": 1, "squad": 0, "score": 0},
		{"id": 3, "name": "Specter", "team": 1, "squad": 0, "score": 0},
		{"id": 4, "name": "Falcon", "team": 0, "squad": 0, "score": 0}]

## Ingest a STRUCTURE_BASELINE into the client collision store. Baselines arrive PER REGION (one each
## as the player moves), so ACCUMULATE — never reset, or only the last region would block (the
## renderer's world_view accumulates the same way). Prediction collides against this exactly like the
## server's SimLoop._step_normal.
func _rebuild_struct_store(bytes: PackedByteArray) -> void:
	if _piece_cat == null:
		return
	if _struct_store == null:
		_struct_store = StructureStore.new(_piece_cat)
	if _pred != null:
		_pred.structures = _struct_store
	for rec: Dictionary in Protocol.decode_structure_baseline(bytes)["records"]:
		var placed := _struct_store.place(int(rec["id"]), int(rec["type"]), rec["cell"],
			int(rec["yaw"]), int(rec["owner"]), int(rec["building_id"]))
		if not placed.is_empty():
			placed["chunks"] = int(rec["chunks"])   # carry partial-destruction so collision matches

## Apply a STRUCTURE_DELTA (place / remove / chunk-damage) to the collision store.
func _apply_struct_delta_to_store(bytes: PackedByteArray) -> void:
	if _struct_store == null:
		return
	var d := Protocol.decode_structure_delta(bytes)
	match int(d["op"]):
		Protocol.OP_PLACE:
			var rec: Dictionary = d["rec"]
			var placed := _struct_store.place(int(rec["id"]), int(rec["type"]), rec["cell"],
				int(rec["yaw"]), int(rec["owner"]), int(rec["building_id"]))
			if not placed.is_empty():
				placed["chunks"] = int(rec["chunks"])
		Protocol.OP_REMOVE:
			_struct_store.remove(int(d["id"]))
		Protocol.OP_CHUNK:
			var r := _struct_store.get_record(int(d["id"]))
			if not r.is_empty():
				r["chunks"] = int(d["mask"])

## A building collapsed — drop its pieces from collision so the client doesn't snag on phantom rubble.
func _collapse_struct_store(building_id: int) -> void:
	if _struct_store == null or building_id == 0:
		return
	var drop: Array = []
	for id in _wv.structures():
		if int(_wv.structures()[id].get("building_id", 0)) == building_id:
			drop.append(int(id))
	for id in drop:
		_struct_store.remove(int(id))

## The vehicle id whose seat the local player currently occupies, or -1. Drives the F=exit prompt.
## Seats are replicated on VehicleState (seat-index -> occupant pawn id, 0 = empty).
func _in_vehicle() -> int:
	if my_id == 0:
		return -1
	var vehs: Dictionary = _wv.vehicles()
	for vid in vehs:
		var vs = vehs[vid]
		if vs == null:
			continue
		for occ in vs.seats:
			if int(occ) == my_id:
				return int(vid)
	return -1

## Live grenade world-positions for the HUD danger indicator: the renderer's cosmetic pool (local
## throws + remote GRENADE_FX), plus a pinned synthetic one under --grenade-danger-test.
func _grenade_danger_sources() -> Array:
	var out: Array = []
	if _renderer != null:
		out = _renderer.live_grenade_positions()
	if _grenade_danger_test and _pred != null and _pred.predicted != null:
		out.append(_pred.predicted.eye_position() + Vector3(3.0, 0.0, 0.0))   # QA: a grenade ~3 m away
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

## Per-weapon aim-down-sights FOV (absolute degrees, horizontal). The DMR is scoped (strong zoom); the
## RPG barely zooms (no sights); everything else gets a moderate iron-sight zoom. Scaled off the
## player's hip FOV so it tracks their FOV setting. Client-only visual (AGENTS.md §7).
func _ads_fov(weapon_id: int) -> float:
	var base: float = _settings.fov
	match weapon_id:
		Weapon.DMR: return base * 0.38   # scoped marksman zoom
		Weapon.RPG: return base * 0.88   # launcher: barely zooms
		_: return base * 0.72            # iron-sight zoom (AR/SMG/pistol)

## True when the equipped weapon uses a magnified scope overlay (only the DMR today).
func _is_scoped(weapon_id: int) -> bool:
	return weapon_id == Weapon.DMR

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

## M12: optimistic squad-leader check for the build cycle's FOB entry. Leadership isn't replicated
## (the server tracks join order), so we approximate it as "lowest id in my squad" — the common case,
## and the server authoritatively rejects PLACE_FOB from a non-leader regardless.
func _is_squad_leader(team: int) -> bool:
	var my_squad := _my_squad_id(team)
	var lowest := -1
	var found := false   # require my_id to actually be in the roster (no FOB on a not-yet-known roster)
	for rw in _wv.roster():
		if int(rw.get("team", -1)) == team and int(rw.get("squad", -1)) == my_squad:
			var rid := int(rw["id"])
			if not found or rid < lowest:
				lowest = rid
				found = true
	return found and lowest == my_id

## M12: collect raw mouse-wheel steps while the build tool is active (the wheel cycles the piece;
## InputEventMouseButton carries the direction the swap_weapon action can't).
func _input(event: InputEvent) -> void:
	if _build_ctrl == null or not _build_ctrl.active:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_WHEEL_UP: _build_wheel += 1
			MOUSE_BUTTON_WHEEL_DOWN: _build_wheel -= 1

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

## M12-P3: the team's FOBs from the latest FOB_LIST, mapped to DeploySpawn.enumerate's shape
## ({squad, enabled}). The server re-validates; the position is resolved server-side from the squad.
func _build_fob_candidates() -> Array:
	if _fob_menu_test:
		return [{"squad": 0, "enabled": true}]   # --fob-menu-test: a fake enabled FOB for a deploy-screen QA shot
	var out: Array = []
	for f in _team_fobs:
		out.append({"squad": int(f["squad"]), "enabled": int(f.get("enabled", 0)) == 1})
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

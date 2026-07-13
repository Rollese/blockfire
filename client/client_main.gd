extends Node
## Client composition root — M7 C1 (rendered client).
## Wires all client-side components; owns NO authority or rule logic (AGENTS.md §7).
## Authority lives on the server; this file connects UI/input/prediction/rendering only.

const Protocol := preload("res://shared/net/protocol.gd")
const QaFlags := preload("res://client/qa_flags.gd")   # table-driven --*-test QA-flag registry (§D3)
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
var _recon_peak := 0.0   # largest reconcile correction (m) this dbg window — the A1 apex-feel meter
const RECON_DEADZONE := 0.12   # corrections under this (m) are noise — left to smooth 30->60 interpolation
                               # instead of the _pos_err ease. Was 0.04, right at the per-connect
                               # prediction-lead jitter magnitude (~4-6 cm), so constant tiny corrections
                               # took the active-ease path and never settled -> perceived micro-snapping.
                               # predicted.pos is still set to authority either way; this only changes the
                               # visual easing of sub-12 cm corrections. Genuine desyncs (>RECON_SNAP) snap.
const RECON_SNAP := 2.5        # corrections over this (m) snap (respawn/teleport), not smoothed
const RECON_SMOOTH := 13.0     # per-second decay of _pos_err (~a correction fades over ~150 ms)
# C1a: visual camera-recoil kick — a per-shot upward view punch that recovers. Client-only cosmetic
# (does NOT touch the authoritative aim pitch, so no prediction/desync), on top of the viewmodel kick
# and the crosshair bloom. Feel values — owner-tunable via playtest.
const RECOIL_KICK_PER_SHOT := 0.010   # rad added to the camera pitch per shot (~0.57°)
const RECOIL_KICK_MAX := 0.055        # rad ceiling so sustained auto-fire climbs but caps (~3.1°)
const RECOIL_KICK_RECOVER := 11.0     # per-second decay of the kick (~settles in ~150 ms)
var _recoil_kick := 0.0               # current accumulated visual recoil pitch (radians)
# DBNO downed screen
var _downed_since := -1.0      # _elapsed when the current down began (-1 = not downed)
var _giveup_hold := 0.0        # seconds the give-up key (jump) has been held while downed
var _giveup_sent := false
const INITIAL_BLEEDOUT_SECS := 60.0   # Revive.INITIAL_BLEEDOUT_TICKS/TICK_RATE (1st down); halved per re-down
const GIVEUP_HOLD := 0.8       # seconds to hold to confirm give-up (avoid accidental skip)

# ---- components (all non-scene, headless-safe) ------------------------------
var _settings: ClientSettings
var _map: MapDef
var _conquest: ConquestState
var _wv: WorldView
var _pred: Prediction
var _wpred: WeaponPredictor
var _tick_lead := TickLead.new()   # input-clock pacing from the SELF_STATE buffer-depth byte (tick-lead netcode)
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
var _main_menu: MainMenu    # pre-game menu (skipped when --connect or headless)
var _skip_main_menu := false
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
var _attachments: Attachment        # client mirror of the server attachment catalog; needed by Loadout.sanitize before SET_LOADOUT send
var _struct_store: StructureStore   # client mirror of the server StructureStore; feeds prediction wall collision
var _terrain_grid: TerrainGrid = null   # M15: heightmap grid the client derives (null = flat map); shared by prediction+mirror+render
var _auto_deploy_ref: int = -1    # --deploy=N arg; -1 = not set
var _auto_deploy_sent := false    # only send once
var _flash_test := false          # --flash-test: force the flashbang white-out on (visual QA)
var _suppress_test := false        # --suppress-test: force the suppression screen FX on (visual QA)
var _suppress_qa_on := true         # in suppress-test, gates the forced FX (A/B screenshot sequence flips it)
var _armor_demo := false            # --armor-demo: pin 3 armor-tier dummy soldiers in front of the camera
var _boom_test := false             # --boom-test: pump frag explosions in front of the camera (visual QA)
var _vehicle_test := false          # --vehicle-test: blow up a transport in front of the camera (visual QA)
var _turret_test := false           # --turret-test: an intact transport with its turret traversed off-axis (visual QA)
var _heldweapon_test := false       # --held-weapon-test: 5 side-on dummies, one per weapon silhouette (visual QA)
var _seat_pose_test := false        # --seat-pose-test: standing-vs-seated dummy A/B (vehicle occupant pose QA)
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
var _flinch_test := false          # --flinch-test: pin a hit-flinch-posed dummy beside an upright one
var _reloadpose_test := false      # --remote-reload-test: pin a reload-posed dummy beside an upright one
var _meleepose_test := false       # --remote-melee-test: pin a melee-lunge-posed dummy beside an upright one
var _vaultpose_test := false       # --remote-vault-test: pin a mantle-posed dummy beside an upright one
var _glbshoot_test := false        # --glbshoot-test: GLB hold vs holding-both-shoot clip A/B
var _ads_t := 0.0                   # 0..1 eased aim-down-sights blend (client-only visual zoom/pose)
var _supp_fx := 0.0                 # A6: peak-held suppression FX strength (snaps up, decays slowly so a spike is visible)
const SUPP_FX_DECAY := 1.4          # per-second decay of the suppression veil after a spike (~0.7 s to clear)
const ADS_RATE := 16.0              # ADS ease speed (per second); ~1/e in ~60 ms
var _prev_grounded := true          # for the local landing viewmodel dip (airborne->grounded edge)
var _prev_vy := 0.0                 # local vertical velocity from the previous frame (fall impact speed)
const LAND_VY := 3.5                # min downward speed (m/s) for a landing to kick the viewmodel dip
const ENGINE_AUDIO_RANGE := 200.0  # m: voice the engine of the nearest running vehicle within this
var _engine_test := false          # --engine-test: force the engine loop on (audio QA, no vehicle needed)
var _sprint_test := false           # --sprint-test: freeze the viewmodel sprint-lowered for a visual QA shot
var _vm_climb_test := false          # --vm-climb-test: freeze the viewmodel climb/vault-lowered for a visual QA shot
var _reload_test := false           # --reload-test: freeze the viewmodel mid-reload for a visual QA shot
var _whiz_test := false             # --whiz-test: pump synthetic near-miss rounds across the view (crack/whiz QA)
var _smoke_test := false            # --smoke-test: pop a smoke cloud in front of the camera (visual QA)
var _grenade_test := false          # --grenade-test: lob cosmetic grenades across the view (visual QA)
var _gadget_test := false           # --gadget-test: place sample deployed gadgets in view (visual QA)
var _gadget_bytes := PackedByteArray()   # last GADGET_LIST bytes — skip the rebuild on an unchanged heartbeat
var _emplacement_bytes := PackedByteArray()  # last EMPLACEMENT_LIST bytes — skip the rebuild on an unchanged tick
var _emplacements: Array = []            # M19 P4: last decoded LMG-nest list (mount targeting / debug)
var _deployed_ladder_bytes := PackedByteArray()  # M19 grapple: last DEPLOYED_LADDER_LIST bytes — skip rebuild on unchanged tick
var _deployed_ladders: Array = []        # M19 grapple: last decoded deployed-rope list [{id,x,z,bottom_y,top_y,cuttable}]
var _support_bytes := PackedByteArray()  # last SUPPORT_LIST bytes — skip the rebuild on an unchanged heartbeat
var _downed_bytes := PackedByteArray()   # last DOWNED_LIST bytes — skip the rebuild on an unchanged heartbeat
var _fob_bytes := PackedByteArray()      # last FOB_LIST bytes — skip rework on an unchanged heartbeat
var _team_fobs: Array = []               # M12-P3: own-team FOBs {squad, under_construction, enabled} for deploy
var _revive_marker_test := false    # --revive-marker-test: downed friendly + revive marker (visual QA)
var _downed_urgency_test := false   # --downed-urgency-test: row of downed dummies at varying bleed urgency (visual QA)
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
var _stim_charges: int = 0         # latest Medic Combat Stim charges remaining from SELF_STATE (M19 P2b HUD)
var _stim_ticks: int = 0           # latest remaining stim-buff ticks from SELF_STATE (M19 P2b; drives predicted stim_until_tick)
var _bandage_count: int = 0        # latest bandage charges from SELF_STATE (reserved: standing-bleed cure)
var _life_down_count: int = 0      # times downed this life (client mirror; drives the halving bleedout timer)
var _repair_heat: float = 0.0      # latest Engineer repair-tool heat fraction from SELF_STATE (HUD gauge)
var _repair_cooldown: float = 0.0  # latest repair overheat-lockout remaining fraction from SELF_STATE
var _self_stamina: float = 100.0   # latest authoritative stamina from SELF_STATE (sprint reconcile baseline)
var _self_vel_y: float = 0.0       # latest authoritative vertical velocity from SELF_STATE (jump reconcile baseline)
var _self_grounded: bool = true    # latest authoritative grounded flag from SELF_STATE (jump reconcile baseline)
var _self_vaulting: bool = false   # latest authoritative vault flag from SELF_STATE (vault-arc reconcile)
var _self_vault_tick: int = 0      # latest authoritative vault progress from SELF_STATE
var _self_regen_cooldown: float = 0.0   # latest authoritative stamina regen-cooldown (C6 sprint/jump-stamina reconcile)
var _self_sprint_locked: bool = false   # latest authoritative sprint-lockout flag (empty-sprint hysteresis reconcile)
var _conn_lost: bool = false       # in-game disconnect: freeze the loop under the overlay
var _conn_lost_overlay: CanvasLayer = null
var _match_end_overlay: CanvasLayer = null   # victory/defeat end-of-match screen (from MATCH_STATE match_over)
var _reject_reason: String = ""    # last REJECT text — shown on the menu when the disconnect lands
var _my_class: int = 0             # own class from WELCOME (medic revive-rate for the HUD bar)
var _loadout: Dictionary = {}      # M19 P3: client-stored loadout, seeded from WELCOME's class and sent via SET_LOADOUT; source of truth for equipped-gadget reads (class-select UI edits it in Tasks 2-3)
var _throw_charge: float = 0.0     # C3: current grenade hold-charge 0..1 (grows while "throw" is held)
var _throw_charging: bool = false  # whether we're mid-charge on a throwable
const THROW_CHARGE_SECS := 1.1     # hold time to reach full throw strength
var _repair_holding: bool = false  # M19 P2b: whether we've latched GA_REPAIR_START (matches server hold-state)
var _repair_heat_test := false     # --repair-heat-test: drive a demo heat/cooldown cycle for a QA screenshot
var _revive_hold: float = 0.0      # seconds the interact key has been held on a revive target
var _am_bleeding: bool = false     # M16: own standing-bleed flag from SELF_STATE (drives the bleeding cue)
var _bandage_progress: int = 0     # M16: 0..255 server-authoritative bandage cast progress (owner as target)
var _bleeding_ids: Dictionary = {} # M16: teammate ids currently standing-bleeding (from BLEEDING_LIST)
var _bandage_target: int = 0       # M16: id the client is currently holding a BANDAGE_ACTION latch on (0 = none)
# ---- M19 P4: manned LMG nest (mirror the vehicle-seat handling) -------------
var _mounted_nest: int = 0         # id of the LMG nest we're manning (0 = on foot); gates seat-lock + arc-clamp + fire routing
var _mg_heat: int = 0              # manned MG heat 0..255 from SELF_STATE (Task 13 HUD; stored now)
var _mg_ammo: int = 0              # manned MG belt rounds remaining from SELF_STATE (Task 13 HUD; stored now)
var _mg_overheated: bool = false   # manned MG overheat-lockout flag from SELF_STATE (Task 13 HUD; stored now)
# ---- M19 P5: riot shield (Support) ------------------------------------------
var _shield_hp_frac: int = 0       # latest shield HP 0..255 from SELF_STATE (0 = no shield/broken; HUD bar + break-forces-down)
var _grapple_charges: int = 0      # M19 grapple: remaining grapple charges from SELF_STATE (HUD readout)
var _shield_held := false          # local toggle intent: true = player wants the shield raised (OR'd into BTN_SHIELD)
var _shield_key_down := false      # previous-frame "gadget" action state — own edge detector (see _produce_input_frame:
                                    # is_action_just_pressed() would double-toggle on a frame_repeats()==2 catch-up tick,
                                    # since _produce_input_frame can run twice off one gathered Input frame)
# Nest arc/pitch limits — must match data/gadgets.json "lmgnest" (client doesn't load the gadget catalog).
const NEST_HALF_ARC := deg_to_rad(45.0)
const NEST_PITCH_LO := deg_to_rad(20.0)
const NEST_PITCH_HI := deg_to_rad(25.0)
const NEST_MOUNT_RANGE := 1.6      # metres to a friendly, unoccupied nest to man it

# ---- configure (called by bootstrap before add_child) -----------------------
func configure(args: Dictionary) -> void:
	if args.has("connect"):
		_server_ip = String(args["connect"])
		_skip_main_menu = true
	_port = int(args.get("port", _port))
	if args.has("name"):
		_player_name = String(args["name"])
	if args.has("deploy"):
		_auto_deploy_ref = int(args["deploy"])
	_novsync = args.has("novsync")
	if args.has("map"):
		_map_path = "res://maps/%s.json" % String(args["map"])
	# Visual/audio QA flags — one registry row per --*-test flag (see client/qa_flags.gd) sets the
	# matching bool member, replacing the old per-flag parse ladder. Flag meanings live in the table.
	for entry: Dictionary in QaFlags.FLAGS:
		set(String(entry["member"]), args.has(String(entry["flag"])))
	_shot_after = float(args.get("shot-after", -1.0))  # automated screenshot then quit

# ---- _ready -----------------------------------------------------------------
func _ready() -> void:
	# 1. Load settings
	_settings = ClientSettings.new()
	_settings.load_from()
	if not _skip_main_menu:
		_player_name = _settings.player_name
	InputBindings.apply(_settings)
	VideoSettings.apply(_settings)
	_apply_audio_settings()

	# Headless / CI smoke tests skip the rendered main menu.
	if DisplayServer.get_name() == "headless":
		_skip_main_menu = true

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
	var wres := Weapon.load_from_file("res://data/weapons.json")
	if not wres["ok"]:
		push_error("[client] failed to load weapons: %s" % wres["error"])
	# M19 P3: attachment catalog, loaded before WELCOME can ever arrive (network isn't up yet), so
	# _send_loadout()'s sanitize() call always has a real catalog to validate against.
	_attachments = Attachment.load_file("res://data/attachments.json")
	if _attachments == null:
		push_error("[client] failed to load attachments — SET_LOADOUT will send un-sanitized")
	_build_ctrl = BuildController.new(_piece_cat)   # M12: build-tool state machine
	_wpred = WeaponPredictor.new()
	_hud_model = HudModel.new()

	# 4. InputController must be in the tree so _input() fires
	_input_ctrl = InputController.new()
	add_child(_input_ctrl)

	# 5. Pre-game main menu or immediate connect (--connect / headless).
	if _skip_main_menu:
		_start_connection()
	else:
		_show_main_menu()

func _show_main_menu() -> void:
	_main_menu = MainMenu.new()
	add_child(_main_menu)
	_main_menu.configure(_settings, _server_ip, _port)
	_main_menu.connect_requested.connect(_on_main_menu_connect)
	_main_menu.quit_requested.connect(func(): get_tree().quit())

func _on_main_menu_connect(ip: String, port: int, player_name: String) -> void:
	_server_ip = ip
	_port = port
	_player_name = player_name
	# HIDE the menu, don't free it: an unreachable host surfaces as a peer_disconnected event a few
	# seconds from now, and the menu (with its error line) is the only way back — freeing it here
	# used to leave every failed connect on a permanent black screen. Freed on successful WELCOME.
	if _main_menu != null:
		_main_menu.visible = false
	_start_connection()

func _start_connection() -> void:
	if _net != null:
		return
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(_on_connected)
	_net.packet_received.connect(_on_packet)
	_net.peer_disconnected.connect(_on_disconnected)
	_peer = _net.start_client(_server_ip, _port)
	if _peer == null:
		push_error("[client] failed to create ENet host")
		if _main_menu != null:
			_main_menu.visible = true
			_main_menu.set_connect_error("Failed to create network client.")
		_teardown_net()
		return
	print("[client] connecting to %s:%d ..." % [_server_ip, _port])

## Drop the ENet host so a fresh _start_connection can run (retry from the main menu).
func _teardown_net() -> void:
	_peer = null
	if _net != null:
		_net.close()
		_net.queue_free()
		_net = null

## ENet disconnect: covers connect timeouts (unreachable host), server shutdown, kicks, and the
## M8-P3 map-rotation disconnect_all. Before WELCOME -> back to the main menu with an error line;
## in-game -> freeze the world under a clear "connection lost" overlay (auto-reconnect is a
## documented M7 follow-up; the old behavior was a silent freeze that kept sending inputs forever).
func _on_disconnected(_peer_obj: ENetPacketPeer) -> void:
	if my_id == 0:
		print("[client] connection failed/refused (%s:%d)" % [_server_ip, _port])
		_teardown_net()
		if _main_menu != null:
			_main_menu.visible = true
			var why := "Could not connect to %s:%d." % [_server_ip, _port]
			if _reject_reason != "":
				why = "Rejected by server: %s" % _reject_reason
				_reject_reason = ""
			_main_menu.set_connect_error(why)
		else:
			# --connect / headless CLI path: no menu to fall back to.
			push_error("[client] could not connect to %s:%d — exiting" % [_server_ip, _port])
			get_tree().quit(1)
		return
	print("[client] disconnected from server")
	_conn_lost = true
	_teardown_net()
	if _input_ctrl != null:
		_input_ctrl.release_mouse()
	_show_conn_lost_overlay()

func _show_conn_lost_overlay() -> void:
	if _conn_lost_overlay != null:
		return
	_conn_lost_overlay = CanvasLayer.new()
	_conn_lost_overlay.layer = 100
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_conn_lost_overlay.add_child(dim)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_conn_lost_overlay.add_child(box)
	var title := Label.new()
	title.text = "CONNECTION LOST"
	title.add_theme_font_size_override("font_size", 42)
	title.add_theme_color_override("font_color", Color(1.0, 0.45, 0.35))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := Label.new()
	sub.text = "The server closed the connection (shutdown or match rotation).\nRestart the client to reconnect."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	box.add_child(sub)
	var quit := Button.new()
	quit.text = "Quit"
	quit.custom_minimum_size = Vector2(160, 40)
	quit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	quit.pressed.connect(func(): get_tree().quit())
	box.add_child(quit)
	add_child(_conn_lost_overlay)

## Victory / Defeat end-of-match screen (from MATCH_STATE match_over). Anchor/container-based so it
## centres at any resolution. Layer is under the conn-lost overlay so a later disconnect still shows.
func _show_match_end_overlay(winner: int) -> void:
	if _match_end_overlay != null:
		return
	var my := _local_team()
	_match_end_overlay = CanvasLayer.new()
	_match_end_overlay.layer = 99
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_match_end_overlay.add_child(dim)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_match_end_overlay.add_child(box)
	var title := Label.new()
	var col: Color
	if winner < 0:
		title.text = "MATCH OVER"; col = Color(0.90, 0.90, 0.90)
	elif my >= 0 and winner == my:
		title.text = "VICTORY"; col = Color(0.40, 0.95, 0.50)
	else:
		title.text = "DEFEAT"; col = Color(0.95, 0.40, 0.35)
	title.add_theme_font_size_override("font_size", 66)
	title.add_theme_color_override("font_color", col)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("outline_size", 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(title)
	var sub := Label.new()
	var tk: Array = _match_state.get("tickets", [0, 0])
	var t0: int = int(tk[0]) if tk.size() > 0 else 0
	var t1: int = int(tk[1]) if tk.size() > 1 else 0
	sub.text = "Tickets   %d : %d" % [t0, t1]
	sub.add_theme_font_size_override("font_size", 26)
	sub.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(sub)
	add_child(_match_end_overlay)

# ---- physics tick -----------------------------------------------------------
## True while a menu owns the cursor and keyboard: gameplay intent is zeroed (the alive-with-menu
## branch below keeps sending stop-frames — A5) and raw Input reads must not reach gameplay.
func _input_paused_by_menu() -> bool:
	return (_settings_menu != null and _settings_menu.visible) \
		or (_hud_view != null and _hud_view.is_squad_menu_open())

func _physics_process(delta: float) -> void:
	if _net != null:
		_net.poll()
	_elapsed += delta

	if _conn_lost:
		return   # connection lost: world frozen under the overlay, nothing to predict or send

	if my_id == 0:
		return   # not yet welcomed

	var ss: EntityState = _wv.self_state()
	var deployed: bool = ss != null and ss.alive

	# Alive but with the settings menu open: free the cursor and pause input so the player can
	# click the menu without walking/looking. (Without this, the per-tick capture_mouse() below
	# re-grabs the cursor every frame and the centered menu is unclickable.)
	var menu_open: bool = _input_paused_by_menu()

	if deployed and menu_open:
		if _scene_built:
			_input_ctrl.release_mouse()
			_input_ctrl.drain_look()
			if _deploy_menu != null:
				_deploy_menu.visible = false
		# Keep producing input ticks with ZEROED intent while a menu owns the keyboard (A5 fix,
		# playtest 2026-07-05). Stopping production entirely starved the server's input buffer,
		# and starvation reuses the LAST frame — hold W, press Esc, and the soldier kept walking
		# forward unattended. Zeroed frames stop the pawn explicitly, and the buffer stays fed so
		# the tick-lead loop keeps its depth signal (no windup, no re-converge on menu close).
		# Same shape as the photo-mode freeze; skip gather() — menu keystrokes must not reach
		# gameplay state (e.g. the prone toggle).
		var mcmd := {"move_x": 0.0, "move_y": 0.0, "yaw": _input_ctrl.yaw, "pitch": _input_ctrl.pitch, "buttons": 0}
		for _rep in _tick_lead.frame_repeats():
			_produce_input_frame(ss, mcmd.duplicate())
	elif deployed:
		# Gather local input ONCE per physics frame — gather() flips the prone toggle through
		# is_action_just_pressed, so calling it per produced frame would double-flip prone on a
		# catch-up frame — then produce 0/1/2 input ticks from it per the tick-lead loop
		# (docs/specs/netcode-tick-lead.md): 0 = hold (server input buffer too full — let it
		# drain), 1 = normal, 2 = catch up (buffer too shallow). At most one whole-frame adjust
		# per physics frame; the 30->60 reconcile interpolation absorbs it below perception. On
		# a held frame the gathered cmd is simply discarded — look stays live (applied at render
		# rate) and the prone toggle lives in the controller, so nothing is lost but the intent
		# frame itself, which is the point (let the server drain the surplus).
		var cmd: Dictionary = _input_ctrl.gather(_settings)
		for _rep in _tick_lead.frame_repeats():
			_produce_input_frame(ss, cmd.duplicate())

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

## One full input tick for the local pawn from an already-gathered cmd: predict (movement +
## weapon), send the redundancy bundle, advance _client_tick. Split from _physics_process so the
## tick-lead loop can run it 0/1/2 times per physics frame (hold / normal / catch-up) — see
## docs/specs/netcode-tick-lead.md. Callers pass a fresh duplicate of the gathered cmd: the
## masking below mutates it, and the pending reconcile entries must not share one dict.
func _produce_input_frame(ss: EntityState, cmd: Dictionary) -> void:
	# Mirror authoritative downed state into the predictor so it crawls (1 m/s) like the server
	# instead of predicting full-speed movement the server rejects (the down-state rubber-band).
	_pred.predicted.is_downed = ss.is_downed
	if _photo_mode:
		# Freeze the pawn while free-flying — WASD drives the camera, not the soldier. Keep
		# yaw/pitch so look still works; zero movement + buttons so nothing is sent as intent.
		cmd["move_x"] = 0.0
		cmd["move_y"] = 0.0
		cmd["buttons"] = 0
	elif _in_vehicle() >= 0:
		# Slaved to the vehicle server-side: predicting free movement only rubber-bands the eye, so
		# snap the predicted pawn onto the authoritative seat position (the POV rides along instead
		# of drifting/bouncing). KEEP move_x/move_y: the server steers the vehicle from the DRIVER's
		# last_input axes (server_main._build_vehicle_inputs) — zeroing them here meant the driver
		# could never turn. Non-driver seats ignore the axes and the seated pawn never free-moves
		# (pawn.gd skips movement while in_vehicle), so forwarding them is safe. Mask the movement
		# buttons (jump/crouch/sprint do nothing seated); keep fire so passengers can shoot out.
		cmd["buttons"] = int(cmd["buttons"]) & InputCommand.BTN_FIRE
		_pred.predicted.pos = ss.pos
		_pred.predicted.velocity = Vector3.ZERO
	elif _mounted_nest != 0:
		# M19 P4: manning an LMG nest is the same "server-slaved seat" situation as a vehicle gunner —
		# the server pins the pawn to the nest's seat_world() and meters fire through step_fire. Mask the
		# buttons to FIRE only (that's the MG trigger the server heat-limits; jump/crouch/sprint/reload do
		# nothing mounted), snap the predicted pawn onto ss.pos (the seat) so the POV rides the gun instead
		# of rubber-banding, and zero velocity. Movement axes are irrelevant (an emplacement never moves).
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
					and ((Input.is_action_pressed("fire") and not _input_paused_by_menu()) or _build_test):
				bb |= InputCommand.BTN_SHOVEL   # _build_test forces the shovel so the QA shot shows it rise
			cmd["buttons"] = bb
	# M19 P5: shield input — Support-only hold-to-block. Toggled on the "gadget" key (BTN_SHIELD is
	# OR'd into the buttons this pawn sends, mirroring the server's own gadget==RIOT_SHIELD gate — see
	# server_main.gd's per-tick shield inject). Manual edge detection (not is_action_just_pressed): this
	# function can run TWICE off one gathered Input frame during a tick-lead catch-up tick
	# (frame_repeats()==2), and is_action_just_pressed would read true both times, double-toggling
	# _shield_held back to its original value and silently eating the press.
	# Gate the WHOLE block on not-menu-open, exactly like the build-mode shovel bit above: while a menu
	# owns the keyboard, _physics_process feeds a zeroed mcmd and skips gather() so no keystroke reaches
	# gameplay — reading the raw Input singleton here would flip the shield behind an open menu and
	# resume play with it unexpectedly up. When paused we don't read the key, touch _shield_held, or set
	# the bit (and we DON'T clear _shield_key_down, so no phantom press-edge fires on menu close).
	var shield_equipped: bool = int(_loadout.get("gadget", -1)) == Loadout.GADGET_RIOT_SHIELD
	if not _input_paused_by_menu():
		var shield_gadget_down: bool = Input.is_action_pressed("gadget")
		if shield_equipped and shield_gadget_down and not _shield_key_down:
			_shield_held = not _shield_held
		_shield_key_down = shield_gadget_down
		if not shield_equipped or _shield_hp_frac == 0:
			_shield_held = false   # not the equipped gadget, or the shield is broken — never keep stale intent latched
		# Tighten prediction to the server's want_shield gate (server_main.gd): the shield never raises
		# while downed / climbing / vaulting either, so mirror those here to avoid a transient
		# shield-up misprediction the server would reject. (in_vehicle / mounted_nest / photo handled below.)
		if _shield_held and (_pred.predicted.is_downed or _pred.predicted.climbing or _pred.predicted.vaulting):
			_shield_held = false
		if _shield_held and _in_vehicle() < 0 and _mounted_nest == 0 and not _photo_mode:
			cmd["buttons"] = int(cmd["buttons"]) | InputCommand.BTN_SHIELD
	# Mirror the server's per-tick "shielded" inject (server_main.gd) BEFORE record_cmd below —
	# record_cmd's immediate _advance(cmd) runs Pawn.step synchronously, which reads cmd["shielded"] for
	# the move/sprint cost; setting it any later would miss this tick's prediction (same idiom as the
	# stim inject just below).
	if (int(cmd["buttons"]) & InputCommand.BTN_SHIELD) != 0:
		cmd["shielded"] = true
	# M19 P2b: mirror the server's _step_movement stim inject (server_main.gd) — only set the key when
	# active so the common (unstimmed) tick doesn't pay a Dictionary-mutation cost on every frame.
	# stim_until_tick is re-anchored to _client_tick from SELF_STATE's remaining-ticks field (above,
	# _handle_self_state) each time it arrives; between updates this compares against the same clock the
	# rest of prediction advances on, so the buff window lines up with the server's tick-relative window.
	if _client_tick < _pred.predicted.stim_until_tick:
		cmd["stimmed"] = true
	_pred.record_cmd(_client_tick, cmd)
	# G3a: manning an LMG nest forces the gunner PRONE server-side (emplacement step_occupants). record_cmd's
	# prediction step would otherwise re-derive stance from the FIRE-masked buttons (-> STAND), so the local
	# eye height / pose would mismatch the authority. Pin it here while mounted; the force lifts on its own the
	# tick _mounted_nest drops to 0 (dismount/eject), and the next step re-derives stance from real input.
	if _mounted_nest != 0:
		_pred.predicted.stance = Stance.PRONE

	var buttons: int = int(cmd["buttons"])
	var sprinting: bool = bool(buttons & InputCommand.BTN_SPRINT) \
		and _pred.predicted.stance == Stance.STAND
	var shielded_local: bool = (buttons & InputCommand.BTN_SHIELD) != 0   # M19 P5: mirror for the fire-predict gate below
	# No firing while downed — the server ignores it, so suppress the local tracer/ammo
	# prediction too (otherwise a downed player still sees their own tracers). Also no firing while the
	# shield is up (Pawn.fire_suppressed_by_shield mirrors the server's fire-vs-shield lockout) — a
	# shield-up Support predicts no shot instead of a phantom local tracer the server then rejects.
	var firing: bool = bool(buttons & InputCommand.BTN_FIRE) and not _pred.predicted.is_downed and not _pred.predicted.climbing \
		and not Pawn.fire_suppressed_by_shield(buttons, shielded_local)

	# Predict weapon state — drop_shoot=false here; server gates authoritatively,
	# and SELF_STATE reconciles the client's mag each tick so divergence is transient.
	# A true return means a shot fired this tick -> draw a tracer for immediate feedback.
	if _wpred.step(_client_tick, firing, sprinting, false) and _renderer != null:
		_renderer.fire_tracer(_elapsed)
		_renderer.play_viewmodel_recoil(_elapsed)   # kick the viewmodel on each shot
		if _wpred.weapon != Weapon.RPG:
			_renderer.eject_casing(_elapsed)   # brass flies from the port (no casing for the launcher)
		_ch_fire_bloom = minf(_ch_fire_bloom + 6.0, 26.0)   # bloom the crosshair on each shot (visible hip spread)
		_recoil_kick = minf(_recoil_kick + RECOIL_KICK_PER_SHOT, RECOIL_KICK_MAX)   # visual muzzle climb
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
	if _conn_lost:
		return   # world + HUD frozen under the connection-lost overlay; no actions, no sends
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
	var ads_want: bool = (deployed0 and not menu_open0 and _in_vehicle() < 0 and _mounted_nest == 0 \
		and not Input.is_action_pressed("sprint") and not _pred.predicted.climbing \
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
	# M19 P4: while manning a nest, clamp the local look to the gun's traverse arc so the camera reads as
	# the gun (the server clamps authoritatively — emplacement_server.step sets turret_yaw/pitch from the
	# gunner's p.yaw/p.pitch — this just keeps the client reticle coherent). _input_ctrl.yaw is CAMERA yaw,
	# but the nest facing_yaw is stored in AIM space (server forward=(sin,0,cos)=camera_yaw+PI, see
	# emplacement_server.deploy's atan2 + its clamp of p.yaw), so convert to aim space, clamp, convert back.
	# Pitch is sent unchanged (cmd.pitch == _input_ctrl.pitch == p.pitch), so it clamps directly.
	if _mounted_nest != 0:
		var mn := _find_emplacement(_mounted_nest)
		if not mn.is_empty():
			var aim: float = wrapf(_input_ctrl.yaw + PI, -PI, PI)
			aim = Emplacement.clamp_yaw(aim, float(mn["facing_yaw"]), NEST_HALF_ARC)
			_input_ctrl.yaw = wrapf(aim - PI, -PI, PI)
			_input_ctrl.pitch = Emplacement.clamp_pitch(_input_ctrl.pitch, NEST_PITCH_LO, NEST_PITCH_HI)
	_pos_err = _pos_err.lerp(Vector3.ZERO, clampf(_dt * RECON_SMOOTH, 0.0, 1.0))
	_recoil_kick = lerpf(_recoil_kick, 0.0, clampf(_dt * RECOIL_KICK_RECOVER, 0.0, 1.0))   # C1a: recover the visual recoil
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
	# G2b: raise the first-person riot-shield plate while the local player holds it up (equipped +
	# held + pool not empty). Local presentation only — remote pawns have no shield mesh (no wire bit).
	var _shield_equipped_now: bool = int(_loadout.get("gadget", -1)) == Loadout.GADGET_RIOT_SHIELD
	_renderer.set_shield_up(WorldRenderer.shield_viewmodel_visible(_shield_equipped_now, _shield_held, _shield_hp_frac))
	_renderer.set_ads(_ads_t)   # viewmodel sight pose + bob damping (before update -> _pose_viewmodel reads it)
	# Hide the gun while scoped (you look through the scope, not at the centred gun).
	_renderer.set_viewmodel_scope_hidden((_scope_test or _is_scoped(weapon0)) and _ads_t > 0.6)
	# Hide the gun while downed (DBNO) OR dead: no weapon in hand on the ground (C5), and none on the
	# deploy screen after death — otherwise the first-person gun lingers there still running its walk
	# bob off the last velocity, as if you were moving (playtest).
	var _self_ss_vm: EntityState = _wv.self_state()
	_renderer.set_viewmodel_downed_hidden(_self_ss_vm != null and (_self_ss_vm.is_downed or not _self_ss_vm.alive))
	var cam_fov: float = lerpf(_settings.fov, _ads_fov(weapon0), _ads_t)   # FOV zoom toward the per-weapon ADS FOV
	var _t0 := Time.get_ticks_usec()
	# Camera pitch includes the transient visual recoil kick (view climbs up per shot, then recovers);
	# the authoritative aim sent to the server stays _input_ctrl.pitch, so recoil is cosmetic (C1a).
	var cam_pitch: float = clampf(_input_ctrl.pitch + _recoil_kick, -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
	_renderer.update(_wv, _pred, _elapsed, cam_fov, _input_ctrl.yaw, cam_pitch, eye, _dt)
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
		"self_team": _self_team(),   # friend/foe (relative) colour: compass + objective markers + score band
		"match_state": _match_state,
		"point_positions": _point_positions(),
		"point_radii": _point_radii(),   # per-point TRUE capture radius (matches the ground ring + server)
		"now": _elapsed,
		# C3 additions
		"roster": _killfeed_test_roster() if _killfeed_test else _wv.roster(),
		"self_id": 1 if _killfeed_test else my_id,
		"entities": _build_entities(),
		"throwables": _throwables,
		"downed_mates": _downed_mates(),
		"bleeding_mates": _bleeding_mates(),   # M16: standing-bleeding teammates in bandage range
		"am_bleeding": _am_bleeding,           # M16: offer self-bandage when no world prompt applies
		"vehicles_near": _vehicles_near(),
		"mounted_nest": _mounted_nest,      # M19 P4: id of the nest we're manning (0 = on foot) -> dismount prompt
		"nests_near": _nests_near(),        # M19 P4: friendly unoccupied nests in mount range -> mount prompt
		"cuttable_rope": _nearest_cuttable_ladder_id(_pred.predicted.pos),  # M19 grapple: id of an aged rope in cut range (0 = none) -> "F to cut rope" prompt
		"mg_heat": _mg_heat,                # M19 P4 Task 13: manned MG heat 0..255 -> HUD heat bar
		"mg_ammo": _mg_ammo,                # M19 P4 Task 13: manned MG belt rounds remaining -> HUD belt counter
		"mg_overheated": _mg_overheated,    # M19 P4 Task 13: manned MG overheat-lockout -> HUD overheat flash
		"shield_equipped": int(_loadout.get("gadget", -1)) == Loadout.GADGET_RIOT_SHIELD,  # M19 P5: gates the shield HUD bar
		"shield_hp_frac": _shield_hp_frac,  # M19 P5: shield HP 0..255 from SELF_STATE -> HUD bar
		"grapple_equipped": int(_loadout.get("gadget", -1)) == Loadout.GADGET_GRAPPLE,  # M19 grapple: gates the charges label
		"grapple_charges": _grapple_charges,  # M19 grapple: remaining charges from SELF_STATE -> HUD readout
		"bandage_count": _bandage_count,      # M16/M1: remaining bandages from SELF_STATE -> HUD readout
		"repair_heat": _repair_heat,
		"repair_cooldown": _repair_cooldown,
		"throw_charge": _throw_charge if _throw_charging else 0.0,   # C3 grenade charge bar (0 when idle)
		"stamina_frac": _pred.predicted.stamina / Pawn.STAMINA_MAX,   # bottom-centre stamina bar (shown when spent)
	}
	if _repair_heat_test:   # visual QA: cycle heat 0->overheat->cooldown so the gauge is on-screen
		var phase: float = fmod(_elapsed, 6.0)
		if phase < 4.0:
			ctx["repair_heat"] = phase / 4.0   # ramp to overheat over 4s
			ctx["repair_cooldown"] = 0.0
		else:
			ctx["repair_heat"] = 0.0
			ctx["repair_cooldown"] = (6.0 - phase) / 2.0   # lockout draining over 2s
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
	# BattleBit-style capture-point markers: diamonds anchored over each point in the world (letter +
	# distance), coloured us=blue / enemy=red / neutral=grey. Hidden while dead in the deploy menu, in
	# free-fly, or on the end-of-match screen. Presentation only — fed the camera + live objectives here.
	var _markers_on := _scene_built and not _photo_mode and _match_end_overlay == null \
		and (_deploy_menu == null or not _deploy_menu.visible)
	var _self_p: Vector3 = _pred.predicted.pos if _pred != null else Vector3.ZERO
	_hud_view.update_objective_markers(_camera, _objectives(), _self_team(), _self_p, _markers_on)
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
			_life_down_count += 1   # mirror the server's per-life down count so the timer halves too
		# No give-up accrual while a menu is open: rebinding a key to Space in Settings > Controls
		# while downed used to hold-to-give-up the player from inside the menu.
		var giveup_menu_open: bool = (_settings_menu != null and _settings_menu.visible) \
			or (_hud_view != null and _hud_view.is_squad_menu_open())
		if giveup_menu_open:
			_giveup_hold = 0.0
		elif Input.is_action_pressed("jump"):
			_giveup_hold += _dt
			if _giveup_hold >= GIVEUP_HOLD and not _giveup_sent and _peer != null:
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL, Protocol.encode_give_up(), ENetPacketPeer.FLAG_RELIABLE)
				_giveup_sent = true
		else:
			_giveup_hold = 0.0
		var window_secs: float = INITIAL_BLEEDOUT_SECS / pow(2.0, float(maxi(_life_down_count - 1, 0)))
		var secs_left: float = maxf(0.0, window_secs - (_elapsed - _downed_since))
		_hud_view.set_downed(true, secs_left, _nearest_friendly_dist(sds), clampf(_giveup_hold / GIVEUP_HOLD, 0.0, 1.0), _being_revived)
	elif _downed_test:
		# Visual QA: force the DBNO overlay (bleeding-out countdown + nearest-friendly distance).
		_hud_view.set_downed(true, 6.0, 12.0, 0.0, false)
	elif _downed_since >= 0.0:
		_downed_since = -1.0
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
		var scoped0: bool = _scope_test or _is_scoped(weapon0)
		_hud_view.set_scope(_ads_t if scoped0 else 0.0)
		# C2 red-dot ADS reticle: give iron-sighted weapons a usable aim point while aiming (scoped
		# weapons use the scope overlay instead). ch_alive gates it to a live, deployed pawn.
		_hud_view.set_reddot(ch_alive and _ads_t > 0.5 and not scoped0)
		# M5.5-P3 flashbang white-out from the SELF_STATE blind byte (cleared on death/deploy).
		# --flash-test forces a strong-but-translucent veil so the world shows through (visual QA);
		# it still routes through blind_intensity so the real render chain is exercised.
		var blinded := hs != null and hs.alive and not hs.is_downed
		var blind_ticks := 34 if _flash_test else (_blind_ticks if blinded else 0)
		_hud_view.set_blind(HudModel.blind_intensity(blind_ticks))
		# M5.5-P2 suppression screen FX from the SELF_STATE suppression byte (same gating as blind:
		# only while alive + not downed). --suppress-test forces a strong veil for visual QA.
		var supp := (0.8 if _suppress_qa_on else 0.0) if _suppress_test else (_suppression if blinded else 0.0)
		# Peak-hold the veil: snap up to a new suppression peak instantly, then decay slowly. The server
		# bleeds suppression off ~0.04/tick, so a near-miss spike would otherwise flash for one frame and
		# vanish — this keeps it on screen long enough to actually register (A6). Cleared on death/downed.
		var supp_target := HudModel.suppression_intensity(supp)
		if blinded or _suppress_test:
			_supp_fx = maxf(supp_target, _supp_fx - SUPP_FX_DECAY * _dt)
		else:
			_supp_fx = 0.0
		_hud_view.set_suppression(_supp_fx)

	# ---- C3: revive intent (no self-recovery — a teammate must revive you, BattleBit-style) ----
	var sss: EntityState = _wv.self_state()
	var is_downed: bool = sss != null and sss.alive and sss.is_downed
	# Downed players have no self-action — no self-bandage and no self-revive (removed 2026-07-03): a
	# teammate must revive you, or you bleed out via the halving bleedout (give-up = hold jump on the
	# downed screen). Only offer revive/vehicle/interact intent while UP.
	if not is_downed:
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
		# M19 P4: mount an LMG nest — single F press when the prompt offers a friendly, in-range nest.
		if ip != null and String(ip.get("action", "")) == "mount_nest" \
				and Input.is_action_just_pressed("interact") and _peer != null:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_emplacement_action(Protocol.EA_MOUNT, int(ip["target"])),
				ENetPacketPeer.FLAG_RELIABLE)
		# M19 P4: dismount — single F press while manning (the prompt switched to "dismount_nest").
		if ip != null and String(ip.get("action", "")) == "dismount_nest" \
				and Input.is_action_just_pressed("interact") and _peer != null:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_emplacement_action(Protocol.EA_DISMOUNT, int(ip["target"])),
				ENetPacketPeer.FLAG_RELIABLE)
		# M19 grapple: cut a nearby aged rope — single F press when the prompt offers a cuttable rope.
		# The server re-validates range + arm-time in _grapples.cut; a stale id is harmlessly ignored.
		if ip != null and String(ip.get("action", "")) == "cut_rope" \
				and Input.is_action_just_pressed("interact") and _peer != null:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_cut_ladder(int(ip["target"])), ENetPacketPeer.FLAG_RELIABLE)
		if ip != null and String(ip.get("action", "")) == "revive" and interact_held and _peer != null:
			_revive_hold += _dt
			# Match the SERVER's completion time: a medic revives in half the ticks — the bar used to
			# always show the 3 s non-medic fill, so a medic's revive completed at ~50% on-screen.
			var revive_time: float = float(Revive.revive_ticks(_my_class == Loadout.MEDIC)) / 30.0
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

		# ---- M16: bandage intent (hold F on a bleeding mate, or self-bandage while bleeding) ----
		# The server owns the channel + completion; the client latches BANDAGE_ACTION while F is held
		# and mirrors the server-authoritative bandage_progress on the (reused) revive hold-bar.
		var bact: String = String(ip.get("action", "")) if ip != null else ""
		if (bact == "bandage" or bact == "self_bandage") and interact_held and _peer != null:
			var btgt: int = int(ip["target"])
			if _bandage_target != btgt:
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
					Protocol.encode_bandage_action(btgt, true), ENetPacketPeer.FLAG_RELIABLE)
				_bandage_target = btgt
			if _hud_view != null:
				_hud_view.set_revive_progress(clampf(float(_bandage_progress) / 255.0, 0.0, 1.0))
		elif _bandage_target != 0:
			if _peer != null:
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
					Protocol.encode_bandage_action(_bandage_target, false), ENetPacketPeer.FLAG_RELIABLE)
			_bandage_target = 0
			if _hud_view != null:
				_hud_view.set_revive_progress(0.0)

	# ---- C3: one-shot actions (throw / throwable_cycle / gadget / squad_menu) ----
	var alive_and_deployed: bool = sss != null and sss.alive and not sss.is_downed
	if not alive_and_deployed:
		# Downed / dead / deploying: cancel any in-progress grenade charge. The whole throw block below
		# is gated on alive_and_deployed, so a player downed mid-charge would otherwise never hit the
		# reset at its tail and the throw/charge indicator would freeze on the HUD (playtest bug).
		_throw_charging = false
		_throw_charge = 0.0
		# Same reasoning for a latched REPAIR hold: without this, a player downed mid-repair would
		# leave the server-side latch (and our local flag) stuck on past the point the input block
		# below stops running (it's gated on alive_and_deployed).
		if _repair_holding and _peer != null:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_gadget_action(Protocol.GA_REPAIR_STOP, Vector3.ZERO, Vector3.ZERO, 0), ENetPacketPeer.FLAG_RELIABLE)
		_repair_holding = false
	if alive_and_deployed and _peer != null:
		# Build tool out = no combat: while build mode is active (or a menu is open) the combat
		# one-shots below are locked, so a place-click / habitual keypress can't also fire, throw,
		# melee, detonate, or change fire mode.
		var building: bool = _build_ctrl != null and _build_ctrl.active
		# Climbing a ladder incapacitates combat (server ignores fire/throw/melee/gadget/swap while
		# climbing) — lock the one-shots too so the local player sees no phantom action. A1 playtest.
		# _photo_mode (F8 free-fly): the soldier is frozen and hidden, so no combat input reaches it —
		# else an RPG/grenade/C4 fires from the invisible pawn while you fly the camera around (playtest).
		# M19 P4: manning a nest also locks the combat one-shots (throw / melee / fire-select / gadget /
		# RPG-fire). Those are separate CONTROL sends, NOT covered by the BTN_FIRE-only input mask, so a
		# habitual keypress would otherwise lob a grenade or fire an RPG while riding the gun. The MG
		# trigger flows through the masked input buttons instead (server step_fire reads it).
		var combat_locked: bool = building or menu_open0 or _pred.predicted.climbing or _photo_mode or _mounted_nest != 0

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
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL, Protocol.encode_melee(_wv.view_tick(_elapsed)), ENetPacketPeer.FLAG_RELIABLE)
			if _renderer != null:
				_renderer.play_viewmodel_swing(_elapsed)
			if _audio != null:
				_audio.play_2d("melee")   # own swing whoosh (was a dead catalog entry); hit-confirm stays the hitmarker

		# Quick-swap primary/secondary (mouse wheel): toggle the slot; the swap anim plays when the
		# weapon actually changes (SELF_STATE → set_viewmodel_weapon), so client and server stay in step.
		# Suppressed in build mode, where the wheel cycles the selected piece instead.
		if Input.is_action_just_pressed("swap_weapon") and not _build_ctrl.active and _mounted_nest == 0:
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

		# Throw: hold to charge (longer hold = farther), release to lob. RPG fires immediately on press.
		var throwables_model: Dictionary = _model.get("throwables", {})
		var tlist: Array = throwables_model.get("list", [])
		var active_idx: int = int(throwables_model.get("active", 0))
		var active_kind: int = int((tlist[active_idx] as Dictionary).get("kind", -1)) if active_idx < tlist.size() else -1
		var active_count: int = int((tlist[active_idx] as Dictionary).get("count", 0)) if active_idx < tlist.size() else 0
		# Require count > 0: an empty grenade slot must not charge, send a (server-rejected) throw, or
		# play the local throw cosmetic — otherwise every keypress lobs a phantom grenade that never
		# detonates (round-5 playtest).
		var throwable_is_nade: bool = (active_kind == Grenade.FRAG or active_kind == Grenade.SMOKE) and active_count > 0
		if throwable_is_nade and not combat_locked and Input.is_action_pressed("throw"):
			# Grow the charge while the key is held (clamped to full).
			_throw_charging = true
			_throw_charge = minf(_throw_charge + _dt / THROW_CHARGE_SECS, 1.0)
		else:
			# Not actively charging this frame. Throw only on a CLEAN release (was charging, still a
			# grenade, not combat-locked) — a mid-charge lock (downed / menu / vehicle) or throwable
			# switch cancels without throwing. Always reset the charge afterward.
			if _throw_charging and throwable_is_nade and not combat_locked \
					and Input.is_action_just_released("throw"):
				var aim_dir: Vector3 = -Vector3(sin(_input_ctrl.yaw), 0.0, cos(_input_ctrl.yaw)).normalized()
				var pitch: float = _input_ctrl.pitch
				aim_dir = Vector3(aim_dir.x * cos(pitch), sin(pitch), aim_dir.z * cos(pitch)).normalized()
				var charge: float = _throw_charge
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
					Protocol.encode_grenade_throw(aim_dir, active_kind, charge), ENetPacketPeer.FLAG_RELIABLE)
				if _renderer != null:
					# Own grenade -> friendly=true so it never triggers our own danger warning.
					_renderer.throw_grenade(_pred.predicted.eye_position(),
						Grenade.launch_velocity(aim_dir, charge), active_kind, _elapsed, true)
			_throw_charging = false
			_throw_charge = 0.0
		# RPG throwable fires immediately on press (not a charged lob).
		if Input.is_action_just_pressed("throw") and active_kind == 100 and not combat_locked:
			var rpg_dir: Vector3 = -Vector3(sin(_input_ctrl.yaw), 0.0, cos(_input_ctrl.yaw)).normalized()
			var rpg_pitch: float = _input_ctrl.pitch
			rpg_dir = Vector3(rpg_dir.x * cos(rpg_pitch), sin(rpg_pitch), rpg_dir.z * cos(rpg_pitch)).normalized()
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE,
					_pred.predicted.pos, rpg_dir, 0), ENetPacketPeer.FLAG_RELIABLE)

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

		# Gadget: non-throwable gadget action, branched on the local player's EQUIPPED gadget. The
		# client now sends SET_LOADOUT on join (M19 P3 in progress) and _loadout is the source of
		# truth for what's equipped; default_gadget(_my_class) is only a fallback for the brief window
		# before WELCOME seeds _loadout. The class-select UI (Tasks 2-3) will let a player edit
		# _loadout's gadget choice before this read ever sees anything but the class default.
		var equipped_gadget: int = int(_loadout.get("gadget", Loadout.default_gadget(_my_class)))
		if Input.is_action_just_pressed("gadget") and not combat_locked and equipped_gadget != Loadout.GADGET_REPAIR and equipped_gadget != Loadout.GADGET_RIOT_SHIELD and _mounted_nest == 0:
			var gadget_action: int = Protocol.GA_C4_DETONATE
			var gdir := Vector3.ZERO
			if equipped_gadget == Loadout.GADGET_BREACH:
				gadget_action = Protocol.GA_BREACH_PLACE
				gdir = -Vector3(sin(_input_ctrl.yaw), 0.0, cos(_input_ctrl.yaw)).normalized()
				var gpitch: float = _input_ctrl.pitch
				gdir = Vector3(gdir.x * cos(gpitch), sin(gpitch), gdir.z * cos(gpitch)).normalized()
			elif equipped_gadget == Loadout.GADGET_STIM:
				gadget_action = Protocol.GA_STIM_USE
				gdir = -Vector3(sin(_input_ctrl.yaw), 0.0, cos(_input_ctrl.yaw)).normalized()
				var spitch: float = _input_ctrl.pitch
				gdir = Vector3(gdir.x * cos(spitch), sin(spitch), gdir.z * cos(spitch)).normalized()
			elif equipped_gadget == Loadout.GADGET_SMOKE_WALL:
				gadget_action = Protocol.GA_SMOKE_WALL_PLACE
				gdir = -Vector3(sin(_input_ctrl.yaw), 0.0, cos(_input_ctrl.yaw)).normalized()
				var wpitch: float = _input_ctrl.pitch
				gdir = Vector3(gdir.x * cos(wpitch), sin(wpitch), gdir.z * cos(wpitch)).normalized()
			elif equipped_gadget == Loadout.GADGET_LMG_NEST:
				# M19 P4: deploy a manned LMG nest at the player's feet, facing where they aim (like BREACH).
				# The nest's traverse arc is centred on this facing, so the deploy dir matters. Blocked while
				# already manning one — combat_locked includes _mounted_nest != 0.
				gadget_action = Protocol.GA_LMG_DEPLOY
				gdir = -Vector3(sin(_input_ctrl.yaw), 0.0, cos(_input_ctrl.yaw)).normalized()
				var npitch: float = _input_ctrl.pitch
				gdir = Vector3(gdir.x * cos(npitch), sin(npitch), gdir.z * cos(npitch)).normalized()
			elif equipped_gadget == Loadout.GADGET_GRAPPLE:
				# M19 grapple: fire the hook along the eye ray. The server (grapple_server.deploy) marches
				# p.eye_position() along this dir for an anchor, so the aim vector must be the camera FORWARD.
				# Use the SAME negated yaw+pitch forward every sibling gadget builds (BREACH/STIM/SMOKE/LMG
				# above, and the RPG/grenade throws) so "aim at the ledge, fire, climb" lines up with the view.
				gadget_action = Protocol.GA_GRAPPLE_FIRE
				gdir = -Vector3(sin(_input_ctrl.yaw), 0.0, cos(_input_ctrl.yaw)).normalized()
				var ggpitch: float = _input_ctrl.pitch
				gdir = Vector3(gdir.x * cos(ggpitch), sin(ggpitch), gdir.z * cos(ggpitch)).normalized()
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_gadget_action(gadget_action, _pred.predicted.pos, gdir, 0), ENetPacketPeer.FLAG_RELIABLE)

		# REPAIR is latched (hold to repair, like the bots' struct/vehicle repair): press starts it,
		# release — or losing combat eligibility, or switching off REPAIR — stops it. Gated on the
		# equipped gadget so a C4/RPG/BREACH engineer or any other class never sends REPAIR_START.
		if equipped_gadget == Loadout.GADGET_REPAIR and Input.is_action_pressed("gadget") and not combat_locked:
			if not _repair_holding:
				_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
					Protocol.encode_gadget_action(Protocol.GA_REPAIR_START, Vector3.ZERO, Vector3.ZERO, 0), ENetPacketPeer.FLAG_RELIABLE)
				_repair_holding = true
		elif _repair_holding:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_gadget_action(Protocol.GA_REPAIR_STOP, Vector3.ZERO, Vector3.ZERO, 0), ENetPacketPeer.FLAG_RELIABLE)
			_repair_holding = false

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
		# Once the match is over (victory/defeat overlay up) the deploy menu must NOT be interactable —
		# otherwise its spawn buttons stayed clickable under the end screen and let you re-enter a
		# finished match (server also rejects the request now, but hide it so it can't be clicked).
		var match_over: bool = _match_end_overlay != null
		_deploy_menu.visible = not deployed and not settings_open and not match_over

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
		print("[client-dbg] deployed=%s mouse_mode=%d menu_vis=%s refs=%d motion=%d w=%s fire=%s lead_d=%d holds=%d extras=%d recon_pk=%.3f" % [
			str(dss != null and dss.alive), int(Input.mouse_mode),
			str(_deploy_menu.visible if _deploy_menu != null else false),
			(_deploy_menu.refs.size() if _deploy_menu != null else 0),
			_input_ctrl.motion_events,
			str(Input.is_action_pressed("move_fwd")),
			str(Input.is_action_pressed("fire")),
			_tick_lead.last_depth, _tick_lead.holds, _tick_lead.extras, _recon_peak])
		_recon_peak = 0.0   # per-window peak: correlate a felt snap with its second's line

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
			_reject_reason = Protocol.decode_reject(bytes)
			print("[client] REJECTED: %s" % _reject_reason)
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
		Protocol.Msg.COLLAPSE_WARNING:
			# A building is about to come down (~3 s): rumble cue + a building shake that ramps toward the
			# fall (BattleBit-style). The pieces are still standing until the COLLAPSE below fires.
			var warn := Protocol.decode_collapse_warning(bytes)
			if _renderer != null:
				_renderer.begin_collapse_warning(warn["center"], _elapsed)
			if _audio != null:
				_audio.play_at("explosion", warn["center"])   # low boom cue (no dedicated rumble sound yet)
		Protocol.Msg.COLLAPSE:
			var _bid := Protocol.decode_collapse(bytes)
			print("[client] building %d collapsed" % _bid)   # also fires on join-replay (A3 ghost-ladder fix)
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
		Protocol.Msg.VAULT_FX:
			var vl: Dictionary = Protocol.decode_vault_fx(bytes)
			if _renderer != null:
				_renderer.remote_vault(int(vl["vault_id"]), _elapsed)   # remote mantle/clamber pose
		Protocol.Msg.ROCKET_FX:
			var rfx: Dictionary = Protocol.decode_rocket_fx(bytes)
			if _renderer != null:
				_renderer.fire_rocket(rfx["origin"], rfx["dir"], _elapsed)   # remote rocket flies + launch flash
		Protocol.Msg.GRENADE_FX:
			var gfx: Dictionary = Protocol.decode_grenade_fx(bytes)
			if _renderer != null:
				# Remote pawn's thrown grenade arcs the shared Grenade model (same as the local thrower),
				# at the charged speed. Same-team throws are friendly -> excluded from the danger warning.
				var g_friendly: bool = int(gfx.get("team", -1)) == _local_team()
				_renderer.throw_grenade(gfx["origin"],
					Grenade.launch_velocity(gfx["dir"], float(gfx.get("charge", 1.0))),
					int(gfx["kind"]), _elapsed, g_friendly)
		Protocol.Msg.GADGET_LIST:
			if bytes != _gadget_bytes:
				_gadget_bytes = bytes   # skip the rebuild on an unchanged 1 Hz heartbeat
				if _renderer != null:
					# Pass our team so the renderer draws each supply bag's resupply/heal ring friendly-only.
					_renderer.set_gadgets(Protocol.decode_gadget_list(bytes), _local_team())
		Protocol.Msg.EMPLACEMENT_LIST:
			if bytes != _emplacement_bytes:
				_emplacement_bytes = bytes   # skip the rebuild on an unchanged tick
				_emplacements = Protocol.decode_emplacement_list(bytes)
				if _renderer != null:
					_renderer.set_emplacements(_emplacements, _local_team(), my_id)
		Protocol.Msg.DEPLOYED_LADDER_LIST:
			# M19 grapple: self-healing list of live deployed ropes (like EMPLACEMENT_LIST). Inject the
			# climb volumes into local prediction so the owner climbs their own rope with no round-trip,
			# and hand the geometry to the renderer for the climb marker.
			if bytes != _deployed_ladder_bytes:
				_deployed_ladder_bytes = bytes   # skip the rebuild on an unchanged tick
				_deployed_ladders = Protocol.decode_deployed_ladder_list(bytes)
				_apply_deployed_ladders()
		Protocol.Msg.SUPPORT_LIST:
			if bytes != _support_bytes:
				_support_bytes = bytes   # skip the rebuild on an unchanged 1 Hz heartbeat
				if _renderer != null:
					_renderer.set_support_links(Protocol.decode_support_list(bytes))
		Protocol.Msg.DOWNED_LIST:
			if bytes != _downed_bytes:
				_downed_bytes = bytes   # skip the rebuild on an unchanged heartbeat
				if _renderer != null:
					_renderer.set_downed_urgency(Protocol.decode_downed_list(bytes))
		Protocol.Msg.BLEEDING_LIST:
			# M16: my team's standing-bleeding ids -> "hold F to bandage" prompt targeting.
			_bleeding_ids = {}
			for bid in Protocol.decode_bleeding_list(bytes):
				_bleeding_ids[int(bid)] = true
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
				if int(det["kind"]) == Protocol.DET_EXPLOSION:
					_renderer.cull_rockets_near(det["pos"], 4.0)   # kill the fly-through cosmetic rocket at a real blast
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
				# clamp to a sane window, fall back to the server smoke duration if unknown.
				var dur := float(int(sm["expire_tick"]) - _last_server_tick) / 30.0
				if dur <= 0.5 or dur > 20.0:
					dur = 13.0
				# Pass the pop velocity so the cloud follows the canister's fall (C3), not a static puff.
				_renderer.spawn_smoke(sm["pos"], float(int(sm["radius"])), dur, _elapsed, sm.get("vel", Vector3.ZERO))

# ---- WELCOME ----------------------------------------------------------------
func _handle_welcome(bytes: PackedByteArray) -> void:
	var w: Dictionary = Protocol.decode_welcome(bytes)
	my_id = int(w["id"])
	var tick_rate: int = int(w["tick_rate"])
	var cls: int = int(w["class"])
	_my_class = cls   # own class (e.g. medic revives at double rate — the HUD revive bar matches)
	# Seed the loadout for the WELCOME-assigned class from the client's PERSISTED per-class store
	# (loadout-UI redesign) so a returning player's remembered picks apply immediately — falling back
	# to the class default for a class never edited on this client. _send_loadout() re-sanitizes.
	var stored: Dictionary = _settings.get_class_loadout(cls) if _settings != null else {}
	_loadout = stored if not stored.is_empty() else Loadout.default_loadout(cls)
	_loadout["class"] = cls   # authoritative: honour the class WELCOME actually assigned
	_send_loadout()
	# Connected for real — the (hidden) pre-game menu has served its purpose.
	if _main_menu != null:
		_main_menu.queue_free()
		_main_menu = null

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
				# The predictor was armed with the DEFAULT map's geometry in _ready — refresh it or
				# prediction climbs ladders/clamps edges/finds platform floors from the wrong map
				# for the whole session (rubber-band at every ladder/floor/boundary).
				_pred.world_half = _map.world_half
				_pred.set_geometry(_map.ladders, _map.platforms)
				print("[client] adopting server map: %s" % server_map)
			else:
				push_warning("[client] server map '%s' not found locally; keeping %s" % [server_map, _map_path])

	print("[client] WELCOME — id=%d tick_rate=%dHz class=%d map=%s" % [my_id, tick_rate, cls, _map_path.get_file().get_basename()])

	# Build the 3D scene
	_build_scene()

## M19 P3: sanitize _loadout against the client's attachment catalog (never trust an unsanitized
## config over the wire — mirrors the server's own authoritative sanitize) and send it RELIABLY.
## Called once on WELCOME (seeded from the assigned class) and again whenever the class-select
## screen (Tasks 2-3) changes _loadout.
func _send_loadout() -> void:
	_loadout = Loadout.sanitize(_loadout, _attachments)
	if _peer != null:
		_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
			Protocol.encode_set_loadout(_loadout), ENetPacketPeer.FLAG_RELIABLE)

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
		if _deploy_menu != null:
			_deploy_menu.close_loadout_editor()   # A4 round-2: a fresh death screen starts with the loadout editor closed (populate() no longer force-hides it, so a mid-edit FOB refresh can't yank it shut)
		_pos_err = Vector3.ZERO   # drop any residual reconcile offset so respawn doesn't inherit it
		_reconciled = false
		_died_at = _elapsed   # start the respawn-cooldown clock
		_life_down_count = 0  # fresh life next spawn: re-arm the full 60 s bleedout window (revives keep it)
		if _hud_view != null:
			_hud_view.set_squad_menu_open(false)   # don't leave the squad overlay up over the deploy screen
	var just_respawned: bool = alive and not _was_alive
	_was_alive = alive
	if just_respawned:
		_tick_lead.reset()   # the input buffer refills from scratch on deploy; stale phase would mis-adjust
	if just_respawned and _peer != null:
		# Respawn resets the server's fire mode to the weapon default even when the weapon is unchanged
		# (so the SELF_STATE weapon-change branch won't re-send). Re-assert the remembered mode here so
		# a selection survives death (C1/E1).
		_wpred.set_weapon(_wpred.weapon)   # restore remembered mode for the current weapon locally
		_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
			Protocol.encode_set_fire_mode(_wpred.fire_mode), ENetPacketPeer.FLAG_RELIABLE)
	if alive:
		# Mirror downed state BEFORE reconcile so the replayed inputs crawl (1 m/s) on the very tick
		# the down/revive lands — otherwise that transition tick replays full-speed and rubber-bands.
		_pred.predicted.is_downed = ss.is_downed
		# Likewise climbing (replicated): a predicted engage/leave on a different tick than the server
		# would otherwise stick, routing every replayed input through _step_climb (vertical-only) and
		# yanking the pawn each snapshot until the position happened to exit the ladder radius.
		_pred.predicted.climbing = ss.climbing
		# Reconcile movement prediction from authoritative position + pitch. Smooth only a genuine
		# correction (deadzone..snap): ease it into the camera via _pos_err instead of snapping.
		var pre_pos: Vector3 = _pred.predicted.pos
		_pred.reconcile_full(ss.pos, ss.yaw, ss.pitch, int(hdr["last_input_tick"]), _self_stamina, _self_vel_y, _self_grounded, _self_vaulting, _self_vault_tick, _self_regen_cooldown, _self_sprint_locked)
		var cl: float = (pre_pos - _pred.predicted.pos).length()
		_recon_peak = maxf(_recon_peak, cl)   # A1 meter: is the residual apex feel a real correction?
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
				_deploy_menu.setup_loadout(_loadout.duplicate(true), _attachments)  # M19 P3: pre-fill the editor
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
				_deploy_menu.setup_loadout(_loadout.duplicate(true), _attachments)  # M19 P3: pre-fill the editor
				_deploy_menu_populated = true
			_deploy_menu.visible = true
			if not _awaiting_deploy:
				_deploy_menu.set_respawn_cooldown(_respawn_cooldown_left())

# ---- M19 grapple: deployed-rope list -> local climb prediction + renderer -----
# Called when a fresh DEPLOYED_LADDER_LIST arrives. Builds {bottom,top,radius} climb volumes from the
# wire rows and (a) feeds them into the local prediction loop so the OWNER climbs their own freshly-fired
# rope without waiting on a server round-trip, and (b) hands the raw list to the renderer for the marker.
func _apply_deployed_ladders() -> void:
	var vols: Array = []
	for l in _deployed_ladders:
		var x := float(l["x"]); var z := float(l["z"])
		vols.append({"bottom": Vector3(x, float(l["bottom_y"]), z),
			"top": Vector3(x, float(l["top_y"]), z), "radius": Grapple.LADDER_RADIUS})
	if _pred != null:
		_pred.deployed_ladders = vols   # forwarded into SimLoop.deployed_ladders (climb-capture mirror)
	if _renderer != null:
		_renderer.set_deployed_ladders(_deployed_ladders, my_id)

# M19 grapple: id of the nearest cuttable deployed rope within CUT_RADIUS of `pos` (x,z), 0 if none.
# Only ropes the server has flagged `cuttable` (aged past the arm window) count; the server re-checks
# range + arm-time on receipt, so this is just the client-side prompt/emit gate.
func _nearest_cuttable_ladder_id(pos: Vector3) -> int:
	var best_id := 0
	var best_d := Grapple.CUT_RADIUS
	for l in _deployed_ladders:
		if not bool(l["cuttable"]):
			continue
		var dxz := Vector2(pos.x - float(l["x"]), pos.z - float(l["z"])).length()
		if dxz <= best_d:
			best_d = dxz; best_id = int(l["id"])
	return best_id


# ---- SELF_STATE -------------------------------------------------------------
func _handle_self_state(bytes: PackedByteArray) -> void:
	var d: Dictionary = Protocol.decode_self_state(bytes)
	# Switch weapon if server assigned a different one (e.g. class change)
	if int(d["weapon"]) != _wpred.weapon:
		_wpred.set_weapon(int(d["weapon"]))
		# The server resets fire mode to the weapon default on a swap; re-assert this weapon's
		# remembered mode so its gating matches the client's persisted selection (C1/E1).
		if _peer != null:
			_net.send_to(_peer, NetHost.CHANNEL_CONTROL,
				Protocol.encode_set_fire_mode(_wpred.fire_mode), ENetPacketPeer.FLAG_RELIABLE)
	# Reconcile ammo from authority — no client rule logic, just snap
	_wpred.reconcile(int(d["mag"]), bool(d["reloading"]), int(d["reload_remaining"]), _client_tick)
	_wpred.reconcile_reserve(int(d.get("reserve", -1)))   # M17: snap the spare-ammo pool (-1 = absent, keep local)
	# Store throwable list for HUD ctx (C3: SELF_STATE now carries per-kind counts)
	_throwables = d.get("throwables", [])
	_being_revived = bool(d.get("being_revived", false))   # downed-screen "being revived" indicator
	_suppression = float(d.get("suppression", 0.0))        # M5.5-P2: own suppression (M7 renders screen FX)
	_blind_ticks = int(d.get("blind_ticks", 0))            # M5.5-P3: remaining flashbang-blind ticks (white-out)
	_stim_charges = int(d.get("stim_charges", 0))          # M19 P2b: remaining Medic Combat Stim charges (HUD)
	_stim_ticks = int(d.get("stim_ticks", 0))               # M19 P2b: remaining stim-buff ticks (server-authoritative)
	# Mirror the buff onto the predicted pawn (like blind_ticks mirrors onto HUD white-out): the server
	# reports REMAINING ticks from ITS tick, so re-anchor to the client's own tick to get an absolute
	# stim_until_tick the predicted cmd-build (below, _produce_input_frame) can compare _client_tick
	# against — without this, a human with GADGET_STIM equipped would predict no speed/stamina buff and
	# rubber-band forward every time the server applied one.
	_pred.predicted.stim_until_tick = _client_tick + _stim_ticks
	_bandage_count = int(d.get("bandage_count", 0))        # M16 bandage charges (pouch spent by bandage/revive)
	_am_bleeding = bool(d.get("bleeding", false))          # M16: own standing-bleed flag (bleeding cue)
	_bandage_progress = int(d.get("bandage_progress", 0))  # M16: server bandage cast progress (owner as target)
	_repair_heat = float(d.get("repair_heat", 0.0))        # Engineer repair-tool heat (HUD gauge)
	_repair_cooldown = float(d.get("repair_cooldown", 0.0))# repair overheat-lockout remaining fraction
	_self_stamina = float(d.get("stamina", Pawn.STAMINA_MAX))  # authoritative stamina for sprint reconcile
	_self_vel_y = float(d.get("vel_y", 0.0))                   # authoritative vertical velocity for jump reconcile
	_self_grounded = bool(d.get("grounded", true))             # authoritative grounded flag for jump reconcile
	_self_vaulting = bool(d.get("vaulting", false))            # authoritative vault progress for arc reconcile
	_self_vault_tick = int(d.get("vault_tick", 0))
	_self_regen_cooldown = float(d.get("regen_cooldown", 0.0)) # authoritative stamina regen-cooldown (C6 reconcile)
	_self_sprint_locked = bool(d.get("sprint_locked", false))  # authoritative sprint-lockout flag (hysteresis reconcile)
	# M19 P4: manned LMG-nest state. _mounted_nest gates the seat-lock + arc-clamp below (0 = on foot);
	# _mg_* are stored for the Task 13 MG HUD (heat/ammo/overheat). Server-authoritative each tick.
	_mounted_nest = int(d.get("mounted_nest", 0))
	_mg_heat = int(d.get("mg_heat", 0))
	_mg_ammo = int(d.get("mg_ammo", 0))
	_mg_overheated = bool(d.get("mg_overheated", false))
	# M19 P5 / G2c: a DROP in the authoritative shield fraction while the shield is up means the pool
	# just absorbed a hit — pulse the block/break screen flash (inferred client-side, no wire).
	var _new_shield_frac := int(d.get("shield_hp_frac", 0))
	var _sflash := HudModel.shield_flash_strength(_shield_hp_frac, _new_shield_frac, _shield_held)
	if _sflash > 0.0 and _hud_model != null:
		_hud_model.push_shield_flash(_sflash, _elapsed)
	_shield_hp_frac = _new_shield_frac   # M19 P5: authoritative shield HP 0..255 (HUD bar; 0 forces _shield_held off)
	_grapple_charges = int(d.get("grapple_charges", 0))  # M19 grapple: remaining charges (HUD readout)
	# Tick-lead: feed the post-drain buffer depth to the input-clock loop. Only while input is
	# actually being produced (deployed, on foot; menus now keep producing zeroed frames — A5) —
	# a dead client sends no frames, so its depth reads 0 and would wrongly integrate catch-up
	# phase (windup); seated pawns are server-slaved. -1 = absent byte (old/short packet): idle.
	var ibd := int(d.get("input_buf_depth", -1))
	var lss: EntityState = _wv.self_state()
	if ibd >= 0 and lss != null and lss.alive and _in_vehicle() < 0 and _mounted_nest == 0:
		_tick_lead.on_depth(ibd)

# ---- MATCH_STATE ------------------------------------------------------------
func _handle_match_state(bytes: PackedByteArray) -> void:
	_match_state = Protocol.decode_match_state(bytes)
	# Match over → show the victory/defeat end screen (the server holds a few seconds before it exits
	# or rotates). Without this the round just ends in a CONNECTION LOST overlay (B3 playtest gap).
	if bool(_match_state.get("match_over", false)):
		_show_match_end_overlay(int(_match_state.get("winner", -1)))
	elif _match_end_overlay != null:
		_match_end_overlay.queue_free()   # a new match began (map rotation) — clear the end screen
		_match_end_overlay = null
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
	_apply_env_quality()   # honor persisted "off" toggles on boot (WorldEnvironment exists in client.tscn)

	# M15: derive the SAME terrain grid the server derived (same heightmap PNG + building list ->
	# byte-identical) so prediction, the occlusion/collision mirror, and the rendered mesh all agree.
	# Flat maps (map.terrain empty) return null and keep the original flat-plane path unchanged.
	# NOTE: load_for_map() flattens map.buildings' origin_cell.y in place, so it MUST run before the
	# renderer/prediction read building heights — hence here, before setup() and before any piece render.
	_terrain_grid = Terrain.load_for_map(_map, "res://maps", Callable())
	if _pred != null:
		_pred.terrain = _terrain_grid
	if _struct_store != null:
		_struct_store.terrain = _terrain_grid   # if the mirror already exists; else set at creation

	# WorldRenderer — added under ClientWorld
	_renderer = WorldRenderer.new()
	world_node.add_child(_renderer)
	_renderer.set_terrain(_terrain_grid)   # BEFORE setup(): chooses chunked-terrain vs flat-plane ground
	_renderer.setup(_map, _camera)
	_renderer.use_models = _settings.use_model_characters
	_renderer.piece_catalog = _piece_cat     # M12: lets the renderer derive build-site fill fractions
	# Forward every registry flag that has a renderer-owned demo property (see client/qa_flags.gd) —
	# replaces the old per-flag `_renderer.x_demo = _x_test` copy-paste block.
	for entry: Dictionary in QaFlags.FLAGS:
		if entry.has("renderer"):
			_renderer.set(String(entry["renderer"]), get(String(entry["member"])))

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
	# M19 P3: the deploy screen hosts the class-select / loadout editor; adopt its edits + push them.
	if _deploy_menu.has_signal("loadout_changed"):
		_deploy_menu.loadout_changed.connect(_on_loadout_changed)
	# Loadout-UI redesign: hand the editor the persistence store so per-class picks stick across
	# matches AND servers (the panel loads a class's remembered loadout on switch, saves on edit).
	if _deploy_menu.has_method("set_loadout_store"):
		_deploy_menu.set_loadout_store(_settings)

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
	_apply_audio_settings()
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
	if _peer == null or _net == null:
		return   # disconnected — the deploy menu may still be on screen under the overlay
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
	_apply_audio_settings()
	VideoSettings.apply(_settings)
	_apply_env_quality()

## Apply the graphics-quality settings (SSAO / volumetric fog / glow / sun shadow / render scale)
## to the live client Environment, sun light and viewport (presentation-only, AGENTS.md §7).
## Runs on boot and on every settings-apply so a Performance-preset pick takes effect immediately.
func _apply_env_quality() -> void:
	if _scene_root == null or _settings == null:
		return
	var we := _scene_root.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		we.environment.ssao_enabled = _settings.ssao_enabled
		we.environment.volumetric_fog_enabled = _settings.volumetric_fog_enabled
		we.environment.glow_enabled = _settings.glow_enabled
	var sun := _scene_root.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = _settings.sun_shadow_enabled
	# Render scale + antialiasing. FSR 2.2 is Forward+/Mobile-only (ADR-0005) and provides its own
	# temporal AA — at render_scale 1.0 that's "Native AA" (FSR2's TAA, no upscaling), the game's
	# only antialiasing today. GL Compatibility (no RenderingDevice) falls back to plain BILINEAR.
	var vp := get_viewport()
	if vp != null:
		var fsr_supported := RenderingServer.get_rendering_device() != null
		if _settings.fsr_enabled and fsr_supported:
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			vp.fsr_sharpness = clampf(_settings.fsr_sharpness, 0.0, 2.0)
		else:
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = clampf(_settings.render_scale, 0.5, 1.0)

## A footfall fired by the renderer (local pawn or a visible remote) -> spatial footstep sound.
## Presentation-only (AGENTS.md §7); the AudioDirector handles distance falloff + voice priority.
func _on_footstep(world_pos: Vector3, intensity: float, action: int) -> void:
	if _audio != null:
		_audio.play_at(FootstepAudio.event_for(intensity, Stance.STAND, action), world_pos)

## A bullet terminated in the world — play a spatial thud where it landed (wall/dirt; flesh is
## silent, it gets a blood puff instead). Presentation-only (AGENTS.md §7).
func _on_impact(world_pos: Vector3, kind: int) -> void:
	if _audio == null:
		return
	var snd := ImpactAudio.sound_for(kind)
	if snd != "":
		_audio.play_at(snd, world_pos)

## Drive the audio Master bus from the (previously inert) master_volume setting.
func _apply_audio_settings() -> void:
	if _settings == null:
		return
	var master: float = clampf(_settings.master_volume, 0.0, 1.0)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master, 0.0001)))
	AudioServer.set_bus_mute(0, master <= 0.0)
	var voice_idx := AudioServer.get_bus_index("Voice")
	if voice_idx >= 0:
		var voice: float = clampf(_settings.voice_volume, 0.0, 1.0)
		AudioServer.set_bus_volume_db(voice_idx, linear_to_db(maxf(voice, 0.0001)))
		AudioServer.set_bus_mute(voice_idx, voice <= 0.0)
	if _settings.output_device != "":
		AudioServer.output_device = _settings.output_device
	if _settings.input_device != "":
		AudioServer.input_device = _settings.input_device

# ---- helpers ----------------------------------------------------------------
func _objectives() -> Array:
	if _map == null:
		return []
	var out: Array = []
	var pts: Array = _match_state.get("points", [])
	for i in _map.points.size():
		var pt: Dictionary = pts[i] if i < pts.size() else {}
		var owner: int = int(pt.get("owner", -1))
		# Raise the marker anchor onto the terrain (+~2 m) so the on-screen chip sits over the real
		# point on the hills, and carry the letter id (A/B/C…) + live capture state for the HUD marker.
		var p: Vector3 = _map.points[i]["pos"]
		var anchor := Vector3(p.x, Terrain.height_at(_terrain_grid, p.x, p.z) + 2.0, p.z)
		out.append({"pos": p, "owner": owner, "label": String(_map.points[i]["id"]), "anchor": anchor,
			"attacker": int(pt.get("attacker", -1)), "cap": float(pt.get("cap", 0.0))})
	return out

## This client's team (from the roster), or -1 if unknown — used to colour objective markers
## friend/foe (BattleBit read: us = blue, enemy = red, neutral = grey).
func _self_team() -> int:
	for rw in _wv.roster():
		if int(rw["id"]) == my_id:
			return int(rw["team"])
	return -1

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
		_struct_store.terrain = _terrain_grid   # M15: the mirror grounds pieces on the same heightmap (null = flat)
	if _pred != null:
		_pred.structures = _struct_store
	if _renderer != null:
		_renderer.set_grenade_collision(_struct_store)   # thrown-grenade cosmetics bounce off walls (C4)
	for rec: Dictionary in Protocol.decode_structure_baseline(bytes)["records"]:
		# Under-construction sites are INTANGIBLE on the server (movement collides only against its
		# _store; sites live in _build.sites) — placing their ghost records here made the client
		# predict a solid piece the server walks through: hard rubber-band (and phantom client-side
		# vaults for half-height ghosts) at every build/FOB site. Completion re-emits OP_PLACE with
		# under_construction=0, which lands below as the real collidable piece.
		if int(rec.get("under_construction", 0)) == 1:
			continue
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
			if int(rec.get("under_construction", 0)) == 1:
				return   # intangible ghost site — see _rebuild_struct_store
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

## Per-point capture radius — the SAME value the ground ring is drawn at and the server captures
## within (conquest uses pt["radius"]). The HUD "in the zone" check must use this, not a constant,
## or the status widget appears at a smaller radius than the ring (2026-07-03 playtest bug).
func _point_radii() -> Array:
	if _map == null:
		return []
	var out: Array = []
	for pt: Dictionary in _map.points:
		out.append(float(pt["radius"]))
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

## M16: [{id, dist}] for alive teammates who are standing-bleeding (from BLEEDING_LIST) and within
## bandage range — so the interaction prompt can offer "hold F to bandage squadmate".
func _bleeding_mates() -> Array:
	if _bleeding_ids.is_empty():
		return []
	var sself: EntityState = _wv.self_state()
	if sself == null or not sself.alive or sself.is_downed:
		return []
	var rem: Dictionary = _wv.remotes_at(_elapsed)
	var self_pos: Vector3 = _pred.predicted.pos
	var out: Array = []
	for rid in _bleeding_ids:
		if int(rid) == my_id:
			continue   # self-bandage is handled by the am_bleeding branch, not as a world target
		var e: EntityState = rem.get(int(rid))
		if e == null or not e.alive or e.is_downed:
			continue
		var dist: float = self_pos.distance_to(e.pos)
		if dist <= Bandage.BANDAGE_RANGE:
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

## M19 P4: friendly, unoccupied LMG nests within mount range of the local pawn (mount-prompt candidates).
## Mirrors _vehicles_near: gated on alive + not-downed + not-already-mounted; the server re-validates on
## EA_MOUNT. Reads the Task 11 _emplacements cache (id/pos/facing_yaw/occupant/team per entry).
func _nests_near() -> Array:
	if _mounted_nest != 0:
		return []   # already manning one -> no mount prompt (the dismount prompt takes over)
	var sself: EntityState = _wv.self_state()
	if sself == null or not sself.alive or sself.is_downed:
		return []
	var self_pos: Vector3 = _pred.predicted.pos
	var my_team: int = _local_team()
	var out: Array = []
	for e in _emplacements:
		if int(e.get("occupant", 0)) != 0:
			continue   # someone's already on it
		if int(e.get("team", -1)) != my_team:
			continue   # enemy nest -> can't man it
		# Measure to the SEAT, not the pivot: the server's Emplacement.can_mount checks range to
		# seat_world() (SEAT_BACK behind the pivot along facing). Measuring to e["pos"] would surface
		# "F to man the gun" from the front at 1.0-1.6 m yet get the EA_MOUNT silently rejected.
		var f: float = float(e.get("facing_yaw", 0.0))
		var seat: Vector3 = (e["pos"] as Vector3) - Vector3(sin(f), 0.0, cos(f)) * Emplacement.SEAT_BACK
		var dist: float = self_pos.distance_to(seat)
		if dist <= NEST_MOUNT_RANGE:
			out.append({"id": int(e["id"]), "dist": dist})
	return out

## M19 P4: scan the cached nest list for a specific id; {} if absent. Used to arc-clamp the reticle
## against the manned nest's facing (E) without re-decoding.
func _find_emplacement(nest_id: int) -> Dictionary:
	for e in _emplacements:
		if int(e.get("id", 0)) == nest_id:
			return e
	return {}

## Per-weapon gunfire cue, mapping the equipped weapon to its CC0 caliber sample. Unknown weapons
## fall back to the AR report ("gunfire"). RPG fires via the gadget path, not here.
func _fire_event_for(weapon_id: int) -> String:
	match weapon_id:
		Weapon.SMG: return "gunfire_smg"
		Weapon.DMR: return "gunfire_dmr"
		Weapon.PISTOL: return "gunfire_pistol"
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
## M19 P3: the deploy screen's class-select panel emitted an edited loadout. Adopt a private deep
## copy (the panel emits its own deep copy, but duplicate again so nothing aliases our _loadout) and
## push it. _send_loadout() re-sanitizes against our attachment catalog before sending SET_LOADOUT.
func _on_loadout_changed(cfg: Dictionary) -> void:
	_loadout = cfg.duplicate(true)
	# Persistence is single-owner: the class-select panel (always injected with _settings as its store)
	# writes+saves the per-class loadout on each edit — it is the sole origin of loadout_changed — so we
	# do NOT persist again here. WELCOME seeding only READS the store, so no save path is missed.
	_send_loadout()

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

class_name DeployMenu
extends Control
## Deploy screen: a centered, full-screen spawn-select overlay shown after join or death.
## Emits deploy_requested(spawn_ref) with the chosen ref — pure INTENT only.
## No spawn validation or placement happens here; the server re-validates via DeploySpawn.

signal deploy_requested(spawn_ref: int)
## Emitted when the player clicks a squad button (0-based squad_id).
## client_main's _on_squad_selected sends Protocol.encode_set_squad(squad_id).
signal squad_selected(squad_id: int)
## M19 P3: re-emitted from the embedded ClassSelectPanel whenever the player edits their loadout.
## client_main's _on_loadout_changed adopts the (already-sanitized) cfg and sends SET_LOADOUT.
signal loadout_changed(cfg: Dictionary)

## The refs currently shown, in order. Populated by populate(). Used by tests.
var refs: Array = []

var _vbox: VBoxContainer       # holds the spawn buttons
var _cooldown_label: Label     # "Respawn in N…" — shown during the post-death respawn cooldown
var _squad_hbox: HBoxContainer # holds the squad selection buttons
var _await_label: Label
var _class_select: ClassSelectPanel  # M19 P3: full-screen loadout editor, toggled by _loadout_btn
var _loadout_btn: Button             # reveals/hides the loadout editor overlay

## Number of squad slots to show in the squad selection row.
## Matches the server's dynamic squad model — show enough slots for a typical game.
const SQUAD_DISPLAY_COUNT := 6

func _ready() -> void:
	# Full-screen overlay so the panel is centered and obvious. STOP on the root so a stray
	# click on the dimmed backdrop is swallowed instead of falling through to the 3D world.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_layout()

func _build_layout() -> void:
	if _vbox != null:
		return
	# Dimmed backdrop.
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# Centered panel.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 12)
	center.add_child(panel)
	var title := Label.new()
	title.text = "DEPLOY — choose a spawn"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)
	# M19 P3: a "Loadout" toggle that reveals the class-select editor overlay. Resolves the old
	# TODO below (the class-select screen now exists). The deploy/spawn buttons keep their behavior;
	# deploying uses whatever loadout the editor last emitted (client_main tracks it via _loadout).
	_loadout_btn = Button.new()
	_loadout_btn.text = "Loadout…"
	_loadout_btn.custom_minimum_size = Vector2(260, 40)
	_loadout_btn.pressed.connect(_on_loadout_btn_pressed)
	panel.add_child(_loadout_btn)
	_await_label = Label.new()
	_await_label.text = "Awaiting deploy…"
	_await_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_await_label.visible = false
	panel.add_child(_await_label)
	_cooldown_label = Label.new()
	_cooldown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cooldown_label.visible = false
	panel.add_child(_cooldown_label)
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 6)
	panel.add_child(_vbox)
	# D3: squad selection is NOT on the deploy/spawn screen — you rarely change squads on death, and it
	# cluttered the spawn list. Squad changes live on the in-game squad menu (the "squad_menu" key,
	# set_squad_menu_open) instead. (Loadout, by contrast, DOES live here now — see _loadout_btn.) The
	# squad_selected signal + _on_squad_pressed handler remain for that future host.

	# M19 P3: the class-select / loadout editor, a full-screen overlay hidden until _loadout_btn is
	# toggled on. It emits an already-sanitized cfg; we re-emit it up as loadout_changed so client_main
	# can push SET_LOADOUT. client_main seeds it via setup_loadout() on every (re)populate.
	_class_select = ClassSelectPanel.new()
	_class_select.visible = false
	add_child(_class_select)
	_class_select.loadout_changed.connect(_on_class_select_changed)
	_class_select.closed.connect(_on_class_select_closed)

## Populate the spawn list. Clears any previous buttons.
## squadmates: Array of {pos, team, alive, downed, ...} — may include an optional "name" key
##   for display. Built by client_main from WorldView.roster() + remotes_at().
## vehicles: Array of {pos, team, free_seats, ...} — may include an optional "type_name" key.
##   Built by client_main from WorldView.vehicles(). "team" is best-effort (server re-validates).
## fobs: Array of {squad, enabled} — the team's FOBs (from Msg.FOB_LIST). Only enabled ones are
##   offered (the server re-validates). A FOB spawns its squad's forward bunker.
func populate(team: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = [], fobs: Array = []) -> void:
	refs = []
	# Ensure the layout exists even when called before _ready (e.g. DeployMenu.new() in tests).
	if _vbox == null:
		_build_layout()
	# Fresh spawn list -> not awaiting. Without this, a populate() after death (the alive->dead
	# repopulate) leaves the post-click "Awaiting deploy…" state up with the buttons hidden, and
	# the player is stuck on a buttonless deploy screen.
	set_awaiting(false)
	# Remove old buttons.
	for child in _vbox.get_children():
		child.queue_free()

	var enumerated: Array = DeploySpawn.enumerate(team, map, conquest, squadmates, vehicles, fobs)
	for ref: int in enumerated:
		refs.append(ref)
		var label: String
		if ref >= DeploySpawn.FOB_BASE:
			label = "Squad FOB (%d)" % (ref - DeploySpawn.FOB_BASE)
		elif ref >= DeploySpawn.VEHICLE_BASE:
			# ref - VEHICLE_BASE is the vehicle's stable slot (not an array index); look it up.
			var slot: int = ref - DeploySpawn.VEHICLE_BASE
			var type_name: String = ""
			for v in vehicles:
				if int(v.get("slot", -1)) == slot:
					type_name = String(v.get("type_name", "")); break
			label = "Vehicle: %s" % type_name if type_name != "" else "Vehicle %d" % slot
		elif ref >= DeploySpawn.SQUADMATE_BASE:
			# ref - SQUADMATE_BASE is the mate's stable pawn id (not an array index); look it up.
			var pid: int = ref - DeploySpawn.SQUADMATE_BASE
			var mate_name: String = ""
			for mt in squadmates:
				if int(mt.get("id", -1)) == pid:
					mate_name = String(mt.get("name", "")); break
			label = "Squadmate: %s" % mate_name if mate_name != "" else "Squadmate #%d" % pid
		elif ref == 0:
			label = "HQ"
		else:
			var idx: int = ref - 1
			if idx < map.points.size():
				var pt_id: String = map.points[idx]["id"]
				label = "Point %s" % pt_id if pt_id != "" else "Point %d" % ref
			else:
				label = "Point %d" % ref
		var btn := Button.new()
		btn.text = label
		btn.custom_minimum_size = Vector2(260, 44)
		btn.pressed.connect(_on_deploy_pressed.bind(ref))
		_vbox.add_child(btn)

## Show "awaiting deploy…" state instead of the spawn list.
func set_awaiting(awaiting: bool) -> void:
	if _await_label != null:
		_await_label.visible = awaiting
	if _vbox != null:
		_vbox.visible = not awaiting

## Post-death respawn cooldown: while secs_left > 0, hide the spawn list and show a countdown
## (the server also rejects early deploy requests). At 0, restore the spawn options.
func set_respawn_cooldown(secs_left: float) -> void:
	var cooling := secs_left > 0.0
	if _cooldown_label != null:
		_cooldown_label.visible = cooling
		if cooling:
			_cooldown_label.text = "Respawn in %d…" % int(ceil(secs_left))
	if cooling and _vbox != null:
		_vbox.visible = false
	elif _vbox != null and not _vbox.visible and (_await_label == null or not _await_label.visible):
		_vbox.visible = true

## Helper: emit the signal for a given ref. Used by tests and by the button handler.
func emit_deploy(ref: int) -> void:
	deploy_requested.emit(ref)

func _on_deploy_pressed(ref: int) -> void:
	deploy_requested.emit(ref)

func _on_squad_pressed(squad_id: int) -> void:
	squad_selected.emit(squad_id)

# ---- M19 P3 loadout editor --------------------------------------------------
## Seed the embedded class-select panel with the client's current loadout + attachment catalog.
## client_main calls this whenever it (re)populates the deploy screen, so the editor is pre-filled
## with what's actually equipped. setup() is silent (no loadout_changed), so no feedback loop.
func setup_loadout(cfg: Dictionary, attach) -> void:
	if _class_select == null:
		_build_layout()
	if _class_select != null:
		_class_select.setup(cfg, attach)

func _on_loadout_btn_pressed() -> void:
	if _class_select != null:
		_class_select.visible = true

func _on_class_select_closed() -> void:
	if _class_select != null:
		_class_select.visible = false

## Re-emit the editor's sanitized cfg up to client_main.
func _on_class_select_changed(cfg: Dictionary) -> void:
	loadout_changed.emit(cfg)

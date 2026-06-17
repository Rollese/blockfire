class_name DeployMenu
extends Control
## Deploy screen: a centered, full-screen spawn-select overlay shown after join or death.
## Emits deploy_requested(spawn_ref) with the chosen ref — pure INTENT only.
## No spawn validation or placement happens here; the server re-validates via DeploySpawn.

signal deploy_requested(spawn_ref: int)
## Emitted when the player clicks a squad button (0-based squad_id).
## client_main's _on_squad_selected sends Protocol.encode_set_squad(squad_id).
signal squad_selected(squad_id: int)

## The refs currently shown, in order. Populated by populate(). Used by tests.
var refs: Array = []

var _vbox: VBoxContainer       # holds the spawn buttons
var _squad_hbox: HBoxContainer # holds the squad selection buttons
var _await_label: Label

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
	_await_label = Label.new()
	_await_label.text = "Awaiting deploy…"
	_await_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_await_label.visible = false
	panel.add_child(_await_label)
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 6)
	panel.add_child(_vbox)
	# Squad selection row — minimal: numbered buttons 0..(SQUAD_DISPLAY_COUNT-1).
	var squad_label := Label.new()
	squad_label.text = "Squad:"
	squad_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(squad_label)
	_squad_hbox = HBoxContainer.new()
	_squad_hbox.add_theme_constant_override("separation", 6)
	_squad_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(_squad_hbox)
	for i in SQUAD_DISPLAY_COUNT:
		var sbtn := Button.new()
		sbtn.text = str(i)
		sbtn.custom_minimum_size = Vector2(44, 36)
		sbtn.pressed.connect(_on_squad_pressed.bind(i))
		_squad_hbox.add_child(sbtn)

## Populate the spawn list. Clears any previous buttons.
## squadmates: Array of {pos, team, alive, downed, ...} — may include an optional "name" key
##   for display. Built by client_main from WorldView.roster() + remotes_at().
## vehicles: Array of {pos, team, free_seats, ...} — may include an optional "type_name" key.
##   Built by client_main from WorldView.vehicles(). "team" is best-effort (server re-validates).
func populate(team: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> void:
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

	var enumerated: Array = DeploySpawn.enumerate(team, map, conquest, squadmates, vehicles)
	for ref: int in enumerated:
		refs.append(ref)
		var label: String
		if ref >= DeploySpawn.VEHICLE_BASE:
			var vi: int = ref - DeploySpawn.VEHICLE_BASE
			if vi < vehicles.size():
				var type_name: String = String(vehicles[vi].get("type_name", ""))
				label = "Vehicle: %s" % type_name if type_name != "" else "Vehicle %d" % vi
			else:
				label = "Vehicle %d" % (ref - DeploySpawn.VEHICLE_BASE)
		elif ref >= DeploySpawn.SQUADMATE_BASE:
			var si: int = ref - DeploySpawn.SQUADMATE_BASE
			if si < squadmates.size():
				var mate_name: String = String(squadmates[si].get("name", ""))
				label = "Squadmate: %s" % mate_name if mate_name != "" else "Squadmate %d" % si
			else:
				label = "Squadmate %d" % (ref - DeploySpawn.SQUADMATE_BASE)
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

## Helper: emit the signal for a given ref. Used by tests and by the button handler.
func emit_deploy(ref: int) -> void:
	deploy_requested.emit(ref)

func _on_deploy_pressed(ref: int) -> void:
	deploy_requested.emit(ref)

func _on_squad_pressed(squad_id: int) -> void:
	squad_selected.emit(squad_id)

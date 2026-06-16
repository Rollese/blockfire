class_name DeployMenu
extends Control
## Deploy screen: presents spawn options to the player after join or death.
## Emits deploy_requested(spawn_ref) with the chosen ref — pure INTENT only.
## No spawn validation or placement happens here; the server re-validates via DeploySpawn.

signal deploy_requested(spawn_ref: int)

## The refs currently shown, in order. Populated by populate(). Used by tests.
var refs: Array = []

@onready var _vbox: VBoxContainer = $VBoxContainer
@onready var _await_label: Label = $AwaitLabel

func _ready() -> void:
	# Nodes may not exist in headless/test construction; guard gracefully.
	if has_node("VBoxContainer"):
		_vbox = $VBoxContainer
	else:
		_vbox = VBoxContainer.new()
		add_child(_vbox)
	if has_node("AwaitLabel"):
		_await_label = $AwaitLabel
	else:
		_await_label = Label.new()
		_await_label.text = "Awaiting deploy…"
		_await_label.visible = false
		add_child(_await_label)

## Populate the spawn list. Clears any previous buttons.
func populate(team: int, map: MapDef, conquest: ConquestState) -> void:
	refs = []
	# Ensure _vbox is ready even when called before _ready (e.g. DeployMenu.new() in tests).
	if _vbox == null:
		_vbox = VBoxContainer.new()
		add_child(_vbox)
	# Remove old buttons.
	for child in _vbox.get_children():
		child.queue_free()

	var enumerated: Array = DeploySpawn.enumerate(team, map, conquest)
	for ref: int in enumerated:
		refs.append(ref)
		var label: String
		if ref == 0:
			label = "HQ"
		else:
			var idx: int = ref - 1
			if idx < map.points.size():
				var pt_id: String = map.points[idx]["id"]
				label = pt_id if pt_id != "" else "Point %d" % ref
			else:
				label = "Point %d" % ref
		var btn := Button.new()
		btn.text = label
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

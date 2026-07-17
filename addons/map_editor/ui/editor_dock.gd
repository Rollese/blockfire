@tool
extends Control
## M22 map-editor dock: tool selector + the current MapDocument. Built in code (no .tscn) so the
## whole UI is reviewable as text and cannot drift from the script.
##
## Holds NO map logic — every mutation goes through shared/mapedit/. See map_editor_plugin.gd.

const MapDocument := preload("res://shared/mapedit/map_document.gd")
const MapValidator := preload("res://shared/mapedit/map_validator.gd")

enum Mode { TERRAIN, BUILDING, PROP, MARKER, ROAD }

var undo_redo: EditorUndoRedoManager = null
var doc: MapDocument = null
var mode: Mode = Mode.TERRAIN

var _mode_bar: OptionButton = null
var _status: Label = null
var _validation: RichTextLabel = null

func _ready() -> void:
	custom_minimum_size = Vector2(260, 400)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(vb)

	_mode_bar = OptionButton.new()
	for m in Mode.keys():
		_mode_bar.add_item(String(m).capitalize())
	_mode_bar.item_selected.connect(_on_mode_selected)
	vb.add_child(_mode_bar)

	_status = Label.new()
	_status.text = "No map loaded"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_status)

	_validation = RichTextLabel.new()
	_validation.custom_minimum_size = Vector2(0, 160)
	_validation.bbcode_enabled = true
	vb.add_child(_validation)

func _on_mode_selected(idx: int) -> void:
	mode = idx as Mode

## True when a map is loaded and the plugin should own viewport input.
func is_editing() -> bool:
	return doc != null

func load_map(path: String) -> void:
	doc = MapDocument.load_from(path)
	if doc == null:
		_status.text = "Failed to load %s" % path
		return
	_status.text = "%s — %d buildings, %d points" % [doc.map_name, doc.buildings.size(), doc.points.size()]
	refresh_validation()

func save_map() -> void:
	if doc == null:
		return
	var err := doc.save()
	_status.text = "Saved %s" % doc.source_path if err == OK else "SAVE FAILED (%d)" % err

## Re-run the pure validator and surface its findings. Called after every mutation.
func refresh_validation() -> void:
	if doc == null or _validation == null:
		return
	var errs := MapValidator.check(_doc_dict())
	if errs.is_empty():
		_validation.text = "[color=green]No problems[/color]"
		return
	var lines := "[color=orange]%d problem(s):[/color]\n" % errs.size()
	for e in errs:
		lines += "• %s\n" % e
	_validation.text = lines

func _doc_dict() -> Dictionary:
	return {"world_half": doc.world_half, "buildings": doc.buildings, "roads": doc.roads,
		"points": doc.points, "bases": doc.bases}

## Viewport input entry point — Task 13 fills in the per-mode tools. Returning PASS here means the
## editor camera keeps working while the tools are stubs.
func handle_viewport_input(_camera: Camera3D, _event: InputEvent) -> int:
	return EditorPlugin.AFTER_GUI_INPUT_PASS

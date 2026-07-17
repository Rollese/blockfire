@tool
extends EditorPlugin
## M22 map editor. EDITOR-ONLY: lives in addons/ and never ships in an exported client .pck.
##
## This is a thin shell. All map logic lives in shared/mapedit/ (MapDocument, TerrainBrush,
## RoadBuilder, MapValidator) so the headless suite can test it and the running game can reuse it.
## Anything here that starts growing real logic belongs in shared/mapedit/ instead.
## See docs/superpowers/specs/2026-07-16-map-editor-design.md.

## Named MapEditorDockScript (not "EditorDock") — Godot 4.7 ships a native EditorDock class and a
## const of that name would shadow it, breaking script parse.
const MapEditorDockScript := preload("res://addons/map_editor/ui/editor_dock.gd")

var _dock: Control = null

func _enter_tree() -> void:
	_dock = MapEditorDockScript.new()
	_dock.name = "Map Editor"
	_dock.undo_redo = get_undo_redo()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)

func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

## Route 3D viewport input to the active tool. Returning AFTER_GUI_INPUT_STOP swallows the event so
## the editor's own camera/selection does not also act on it.
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _dock == null or not _dock.is_editing():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	return _dock.handle_viewport_input(camera, event)

func _handles(object: Object) -> bool:
	return _dock != null and _dock.is_editing()

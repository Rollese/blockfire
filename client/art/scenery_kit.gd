class_name SceneryKit
extends Object
## Instantiates imported Broken Vector tree/rock GLBs by catalog id. Presentation-only (AGENTS.md §7).
## Models are exported Y-up with their base on y=0; map `scenery` entries place them at pos + yaw (+ optional scale).

const CATALOG_PATH := "res://data/scenery_catalog.json"

static var _catalog: SceneryCatalog

static func _cat() -> SceneryCatalog:
	if _catalog == null:
		_catalog = SceneryCatalog.load_file(CATALOG_PATH)
	return _catalog

## Build a scenery instance for the given catalog id. Returns null on unknown id or load failure.
static func build(scenery_id: String) -> Node3D:
	var path := _cat().path_for(scenery_id) if _cat() != null else ""
	if path.is_empty():
		push_warning("[SceneryKit] unknown id: %s" % scenery_id)
		return null
	var ps := load(path) as PackedScene
	if ps == null:
		push_warning("[SceneryKit] failed to load: %s" % path)
		return null
	var model := ps.instantiate() as Node3D
	if model == null:
		return null
	var wrapper := Node3D.new()
	wrapper.name = scenery_id
	wrapper.add_child(model)
	return wrapper

static func reset_catalog_for_tests() -> void:
	_catalog = null

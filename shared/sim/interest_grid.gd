class_name InterestGrid
extends RefCounted
## Uniform spatial hash over the XZ plane. Rebuilt each tick (insert), then queried
## per client. query() scans the cell neighbourhood covering `radius` then filters by
## exact distance. See docs/specs/m1-netcode-core.md.

var cell_size: float = 64.0
var _cells: Dictionary = {}   # Vector2i -> Array[int]

func _init(p_cell_size := 64.0) -> void:
	cell_size = p_cell_size

func clear() -> void:
	_cells.clear()

func insert(id: int, pos: Vector3) -> void:
	var k := _key(pos)
	if not _cells.has(k):
		_cells[k] = []
	_cells[k].append(id)

## positions: Dictionary[int id -> Vector3] for exact-distance filtering.
func query(center: Vector3, radius: float, positions: Dictionary) -> Array:
	var out := []
	var ck := _key(center)
	var span := int(ceil(radius / cell_size))
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var arr = _cells.get(Vector2i(ck.x + dx, ck.y + dz))
			if arr == null:
				continue
			for id in arr:
				if center.distance_to(positions[id]) <= radius:
					out.append(id)
	return out

func _key(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / cell_size), floori(pos.z / cell_size))

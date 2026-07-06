class_name CollapseZone
extends RefCounted
## The world-space kill volume of a building coming down. A collapse crushes anyone/anything standing
## inside the footprint (or the "very close" margin band) and below the top of the falling structure.
## Pure + deterministic so the lethality rule is unit-tested away from the server's net/entity state.

## AABB of a building's footprint from its piece `cells` (Vector3i grid cells), expanded horizontally by
## `margin` metres (the "very close" band). Y runs from the ground under the lowest cell to the top of
## the tallest cell. Returns {} for an empty cell list (an already-emptied building crushes nothing).
static func bounds(cells: Array, margin: float) -> Dictionary:
	if cells.is_empty():
		return {}
	var half := BuildGrid.CELL_SIZE * 0.5
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for c: Vector3i in cells:
		var wx := float(c.x) * BuildGrid.CELL_SIZE + half
		var wy := float(c.y) * BuildGrid.CELL_SIZE
		var wz := float(c.z) * BuildGrid.CELL_SIZE + half
		mn.x = minf(mn.x, wx - half); mx.x = maxf(mx.x, wx + half)
		mn.z = minf(mn.z, wz - half); mx.z = maxf(mx.z, wz + half)
		mn.y = minf(mn.y, wy);        mx.y = maxf(mx.y, wy + BuildGrid.CELL_SIZE)
	mn.x -= margin; mx.x += margin
	mn.z -= margin; mx.z += margin
	return {"min": mn, "max": mx}

## Is world position `p` inside the collapse kill volume? XZ within the expanded footprint AND at/below
## the top (anyone standing on/under the building when it drops is crushed). A small vertical slack
## keeps a pawn whose feet sit just above the top course (rooftop stander) in the zone.
const TOP_SLACK := 0.75
static func contains(b: Dictionary, p: Vector3) -> bool:
	if b.is_empty():
		return false
	var mn: Vector3 = b["min"]
	var mx: Vector3 = b["max"]
	return p.x >= mn.x and p.x <= mx.x \
		and p.z >= mn.z and p.z <= mx.z \
		and p.y >= mn.y - TOP_SLACK and p.y <= mx.y + TOP_SLACK

class_name EngineAudio
extends Object
## Pure selection for the single looping engine voice: pick the nearest "running" vehicle to the
## listener within range. A vehicle is running if it's alive (hp > 0) AND either its driver seat is
## occupied OR it's the vehicle the local player is riding (you hear your own engine even as a
## passenger). Presentation-only (AGENTS.md §7) — no gameplay, just which engine to voice.

## vehicles: vid(int) -> VehicleState (needs .pos, .hp, .seats). my_vehicle_id: the local player's
## vehicle vid or -1. Returns {"found": bool, "pos": Vector3}.
static func nearest_running(vehicles: Dictionary, listener: Vector3, my_vehicle_id: int, max_dist: float) -> Dictionary:
	var best_d2 := max_dist * max_dist
	var best_pos := Vector3.ZERO
	var found := false
	for vid in vehicles:
		var vs = vehicles[vid]
		if vs == null or int(vs.hp) <= 0:
			continue
		var driver_in: bool = vs.seats.size() > 0 and int(vs.seats[0]) != 0
		if not (driver_in or int(vid) == my_vehicle_id):
			continue
		var d2 := listener.distance_squared_to(vs.pos)
		if d2 <= best_d2:
			best_d2 = d2
			best_pos = vs.pos
			found = true
	return {"found": found, "pos": best_pos}

class_name SeatPose
extends Object
## Pure: map replicated vehicle seats -> {occupant_pawn_id -> {heading, seat}} so the renderer can
## pose riders seated instead of standing upright at the seat. View-only (AGENTS.md §7): the client
## cross-references the already-replicated VehicleState.seats with the entity pool — no wire change.

## Seated render tuning. A rider is lowered onto the seat and compressed to a shorter, reclined
## silhouette so it reads as sitting in the hull rather than a soldier standing on/through the box.
const SIT_HEIGHT_SCALE := 0.55   # seated torso is markedly shorter than a standing figure
const SIT_RECLINE := 0.16        # rad backward recline about the seat (distinct from a forward crouch)
const SIT_LIFT := 0.35           # m raise so the compressed body sits at seat height, not on the floor

## seats: {vid -> VehicleState}; VehicleState.seats is seat-index -> occupant pawn id (0 = empty).
static func occupants(vehicles: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for vid_v: Variant in vehicles:
		var vs: VehicleState = vehicles[vid_v] as VehicleState
		if vs == null:
			continue
		var seats: Array = vs.seats
		for i in range(seats.size()):
			var occ: int = int(seats[i])
			if occ != 0:
				out[occ] = {"heading": vs.heading, "seat": i}
	return out

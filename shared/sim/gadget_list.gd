class_name GadgetList
extends Object
## Pure flattener: turns the server's live gadget stores into one render list the server broadcasts
## (GADGET_LIST) so human clients can draw deployed C4 / mines / supply bags. Rebuilt from the live
## stores each send, so it always mirrors true server state — placements/detonations/trips/death
## cleanups the server already does are reflected automatically, with no per-removal bookkeeping.

const C4 := 0
const MINE := 1
const BAG := 2

const MAX := 96   # cap so the GADGET_LIST packet stays bounded at scale (u8 count + 11 B/gadget)

## c4: owner_id -> Array of {pos}; mines: Array of {pos, facing}; bags: Array of {pos, kind, team}.
## Returns Array of {kind:int, pos:Vector3, face:Vector3} (face is ZERO for C4/bags). Bag entries also
## carry view-only `subtype` (Gadget.KIND_HEAL / KIND_AMMO) + `team` so human clients can pick the right
## glyph (medic cross vs ammo icon) and draw the resupply/heal ring only for friendlies — presentation
## metadata the server already holds per bag; it does not affect gameplay authority.
static func build(c4: Dictionary, mines: Array, bags: Array) -> Array:
	var out: Array = []
	for owner in c4:
		for entry: Dictionary in c4[owner]:
			if out.size() >= MAX:
				return out
			out.append({"kind": C4, "pos": entry["pos"], "face": Vector3.ZERO})
	for m: Dictionary in mines:
		if out.size() >= MAX:
			return out
		out.append({"kind": MINE, "pos": m["pos"], "face": m.get("facing", Vector3.ZERO)})
	for b: Dictionary in bags:
		if out.size() >= MAX:
			return out
		out.append({"kind": BAG, "pos": b["pos"], "face": Vector3.ZERO,
			"subtype": int(b.get("kind", 0)), "team": int(b.get("team", 0))})
	return out

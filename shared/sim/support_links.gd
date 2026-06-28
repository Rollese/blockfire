class_name SupportLinks
extends Object
## Pure flattener: turns the server's per-tick support actions — a Medic actively healing, a Support
## resupplying, an Engineer repairing a friendly vehicle, a downed teammate being revived — into one
## render list the server broadcasts (SUPPORT_LIST) so human clients can draw a support beam from the
## giver to the target plus a pulsing aura on the target. View-only (AGENTS.md §7), rebuilt each tick
## from live server state, so it always mirrors what the support steps actually did (no per-event
## bookkeeping; a giver that stops helping simply drops out next tick).

const HEAL := 0    # Medic active-give -> green
const AMMO := 1    # Support active-give -> amber
const REPAIR := 2  # Engineer repair kit on a friendly vehicle -> cyan (target is a VEHICLE id)
const REVIVE := 3  # reviver holding a downed teammate -> white-green

const MAX := 64    # cap so the SUPPORT_LIST packet stays bounded at scale (u8 count + 9 B/link)

## events: Array of {giver:int, target:int, kind:int}. Drops self/zero/degenerate links, dedups
## identical (giver,target,kind) triples, sorts deterministically (giver, then target, then kind) so
## the server's change-detect sees a stable packet across ticks, and caps at MAX.
static func build(events: Array) -> Array:
	var seen := {}
	var out: Array = []
	for e: Dictionary in events:
		var giver := int(e.get("giver", 0))
		var target := int(e.get("target", 0))
		var kind := int(e.get("kind", 0))
		if giver <= 0 or target <= 0 or giver == target:
			continue
		var key := "%d:%d:%d" % [giver, target, kind]
		if seen.has(key):
			continue
		seen[key] = true
		out.append({"giver": giver, "target": target, "kind": kind})
	out.sort_custom(func(a, b):
		if a["giver"] != b["giver"]:
			return a["giver"] < b["giver"]
		if a["target"] != b["target"]:
			return a["target"] < b["target"]
		return a["kind"] < b["kind"])
	if out.size() > MAX:
		out = out.slice(0, MAX)
	return out

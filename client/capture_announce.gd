class_name CaptureAnnounce
extends Object
## Pure detector for capture-point ownership changes (M7, view-only — AGENTS.md §7). The client mirrors
## point owners from each MATCH_STATE; this diffs old vs new and tags each change relative to the local
## team so the HUD can banner it (we captured / enemy captured / neutralized). No gameplay authority.

const FRIENDLY := 0   # the local team owns it now (we captured it)
const HOSTILE := 1    # an enemy team owns it now (they captured it / we lost it)
const NEUTRAL := 2    # it went neutral / contested (no owner)

## prev/cur: arrays of owner ints per point (-1 = neutral, else team id). my_team: local team (-1 if
## unknown). Returns [{index, status}] for the points whose owner changed, in point order.
static func diff(prev: Array, cur: Array, my_team: int) -> Array:
	var out: Array = []
	var n := mini(prev.size(), cur.size())
	for i in n:
		var p := int(prev[i])
		var c := int(cur[i])
		if p == c:
			continue
		var status: int
		if c < 0:
			status = NEUTRAL
		elif my_team >= 0 and c == my_team:
			status = FRIENDLY
		else:
			status = HOSTILE
		out.append({"index": i, "status": status})
	return out

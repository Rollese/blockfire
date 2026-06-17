class_name VoicePool
extends RefCounted
## Deterministic finite-voice allocator with priority/gain voice-stealing. Pure (no AudioStreamPlayer);
## the director binds returned slot ids to real players. Keeps the top-N most-important sounds at 128p.

var _capacity: int
var _slots: Array     # per slot: {} = free, else {"priority": int, "gain": float}

func _init(capacity: int) -> void:
	_capacity = maxi(1, capacity)
	_slots = []
	for i in _capacity:
		_slots.append({})

## Request a voice. Returns {"slot": int (-1 if dropped), "evicted": int (-1 if none)}.
func request(priority: int, gain: float) -> Dictionary:
	# 1) free slot?
	for i in _capacity:
		if _slots[i].is_empty():
			_slots[i] = {"priority": priority, "gain": gain}
			return {"slot": i, "evicted": -1}
	# 2) find the weakest active voice (lowest priority, ties -> lowest gain).
	var weakest := -1
	for i in _capacity:
		if weakest == -1 or _is_weaker(_slots[i], _slots[weakest]):
			weakest = i
	# 3) steal only if the request outranks the weakest.
	var w: Dictionary = _slots[weakest]
	if priority > int(w["priority"]) or (priority == int(w["priority"]) and gain > float(w["gain"])):
		_slots[weakest] = {"priority": priority, "gain": gain}
		return {"slot": weakest, "evicted": weakest}
	# 4) otherwise drop.
	return {"slot": -1, "evicted": -1}

func release(slot: int) -> void:
	if slot >= 0 and slot < _capacity:
		_slots[slot] = {}

func active_priorities() -> Array:
	var out: Array = []
	for s in _slots:
		if not s.is_empty():
			out.append(int(s["priority"]))
	return out

static func _is_weaker(a: Dictionary, b: Dictionary) -> bool:
	if int(a["priority"]) != int(b["priority"]):
		return int(a["priority"]) < int(b["priority"])
	return float(a["gain"]) < float(b["gain"])

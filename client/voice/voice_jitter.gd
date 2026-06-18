class_name VoiceJitter
extends RefCounted
## Per-speaker jitter buffer. Ordered insert; drops late (≤ last popped) + duplicates;
## bounded (depth+1) with oldest-evicted overflow; pops lowest seq in order. Pure.

var _depth: int
var _buf: Array = []          # of {seq:int, frame:PackedByteArray}
var _last_popped: int = -1

func _init(depth: int = 3) -> void:
	_depth = depth

## Returns false if the frame was dropped (late / duplicate).
func insert(seq: int, frame: PackedByteArray) -> bool:
	if _last_popped >= 0 and seq <= _last_popped:
		return false
	for item in _buf:
		if item["seq"] == seq:
			return false
	_buf.append({"seq": seq, "frame": frame})
	_buf.sort_custom(func(a, b): return a["seq"] < b["seq"])
	while _buf.size() > _depth + 1:
		_buf.pop_front()
	return true

func ready() -> bool:
	return _buf.size() >= _depth

## Lowest-seq frame, or {} if empty.
func pop() -> Dictionary:
	if _buf.is_empty():
		return {}
	var item: Dictionary = _buf.pop_front()
	_last_popped = item["seq"]
	return item

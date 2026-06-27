class_name Interpolation
extends RefCounted
## Buffers recent remote-entity views and samples them ~DELAY seconds in the past,
## lerping positions between the two surrounding snapshots to hide jitter/loss.

const DELAY := 0.1   # 100 ms render delay
const MAX_BUFFER := 32

var _buf: Array = []   # [{time, tick, view: Dictionary[id->EntityState]}], ascending time

func push(time: float, view: Dictionary, server_tick: int = 0) -> void:
	_buf.append({"time": time, "tick": server_tick, "view": view})
	while _buf.size() > MAX_BUFFER:
		_buf.pop_front()

## The server tick corresponding to the INTERPOLATED render time (now - DELAY) — i.e. the tick at
## which the player actually SEES remote pawns. The client sends this as view_server_tick so the
## server's lag-comp rewinds enemies to where they were RENDERED, not to the latest snapshot (which is
## ~DELAY ahead — the reason you'd otherwise have to lead a moving target to hit it).
func sample_tick(now: float) -> int:
	if _buf.is_empty():
		return 0
	var t := now - DELAY
	if t <= _buf[0]["time"]:
		return int(_buf[0]["tick"])
	var last: Dictionary = _buf[_buf.size() - 1]
	if t >= last["time"]:
		return int(last["tick"])
	for i in range(_buf.size() - 1):
		var a: Dictionary = _buf[i]
		var b: Dictionary = _buf[i + 1]
		if t >= a["time"] and t <= b["time"]:
			var span: float = b["time"] - a["time"]
			var f: float = 0.0 if span <= 0.0 else (t - a["time"]) / span
			return int(round(lerp(float(a["tick"]), float(b["tick"]), f)))
	return int(last["tick"])

## Returns an interpolated id -> EntityState map at (now - DELAY).
func sample(now: float) -> Dictionary:
	if _buf.is_empty():
		return {}
	var t := now - DELAY
	if t <= _buf[0]["time"]:
		return _clone_view(_buf[0]["view"])
	if t >= _buf[_buf.size() - 1]["time"]:
		return _clone_view(_buf[_buf.size() - 1]["view"])
	for i in range(_buf.size() - 1):
		var a = _buf[i]
		var b = _buf[i + 1]
		if t >= a["time"] and t <= b["time"]:
			var span: float = b["time"] - a["time"]
			var f: float = 0.0 if span <= 0.0 else (t - a["time"]) / span
			return _lerp_views(a["view"], b["view"], f)
	return _clone_view(_buf[_buf.size() - 1]["view"])

func _lerp_views(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var out := {}
	for id in b:
		var eb: EntityState = b[id]
		# Clone the latest snapshot so ALL non-interpolated fields (team, stance, lean, alive,
		# health, downed, …) are preserved — then interpolate only pos/yaw. (Previously this built a
		# bare EntityState with just pos/yaw, defaulting team=0 -> every entity rendered as team 0.)
		var e: EntityState = eb.clone()
		if a.has(id):
			var ea: EntityState = a[id]
			e.pos = ea.pos.lerp(eb.pos, f)
			e.yaw = lerp_angle(ea.yaw, eb.yaw, f)
		out[id] = e
	return out

func _clone_view(view: Dictionary) -> Dictionary:
	var out := {}
	for id in view:
		out[id] = (view[id] as EntityState).clone()
	return out

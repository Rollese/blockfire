class_name LagComp
extends RefCounted
## Per-tick position history for lag-compensated hit tests. Stores the minimal pawn
## state needed to rebuild hitboxes (pos, stance, team, alive) keyed by server tick.

const HISTORY := 32     # ticks retained (~1.06s @30Hz)
const MAX_REWIND := 12  # max rewind from 'now' (~400ms)

var _hist := {}         # server_tick -> {id -> {pos, stance, team, alive}}
var _newest := -1

func record(server_tick: int, world: World) -> void:
	var frame := {}
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		frame[id] = {"pos": p.pos, "stance": p.stance, "team": p.team, "alive": p.alive}
	_hist[server_tick] = frame
	_newest = maxi(_newest, server_tick)
	var cutoff := _newest - HISTORY
	for t in _hist.keys():
		if t < cutoff:
			_hist.erase(t)

## True if rewind(server_tick) would clamp — i.e. the caller asked for a tick older than the
## MAX_REWIND horizon (client very far behind). Feeds the `rewind_clamped` telemetry counter.
func clamped(server_tick: int) -> bool:
	return _newest >= 0 and server_tick < _newest - MAX_REWIND

func has_history() -> bool:
	return _newest >= 0

## Drop all frames. Called when recording pauses (no mounted gunner) so a later remount
## can't rewind into seconds-stale frames — history rebuilds fresh from the remount tick.
func clear() -> void:
	_hist = {}
	_newest = -1

## Returns the recorded frame {id -> state} for a tick, clamped into [now-MAX_REWIND, now].
func rewind(server_tick: int) -> Dictionary:
	if _newest < 0:
		return {}
	var t := clampi(server_tick, _newest - MAX_REWIND, _newest)
	while t >= _newest - HISTORY and not _hist.has(t):
		t -= 1
	return _hist.get(t, _hist.get(_newest, {}))

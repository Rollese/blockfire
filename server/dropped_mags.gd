class_name ServerDroppedMags
extends RefCounted
## M2 ammo: server-owned recoverable dropped magazines from hold-R fast reloads. Owner-keyed;
## only the owner can see / pick up their mags. Per-owner rebuilt-on-change reliable broadcast
## (ReliableList pattern). Mags are swept on death/respawn/disconnect and after a TTL.

const ReliableList := preload("res://server/reliable_list.gd")

const TTL_TICKS := 1800   # ~60 s @30 Hz safety despawn

var _mags: Dictionary = {}          # id -> {id, owner, pos, rounds, spawn_tick}
var _next_id: int = 1
var _rl_by_owner: Dictionary = {}   # owner_id -> ReliableList

func spawn(owner: int, pos: Vector3, rounds: int, tick: int) -> int:
	var id := _next_id
	_next_id += 1
	_mags[id] = {"id": id, "owner": owner, "pos": pos, "rounds": rounds, "spawn_tick": tick}
	return id

func get_mag(id: int) -> Dictionary:
	return _mags.get(id, {})

func remove(id: int) -> void:
	_mags.erase(id)

## Remove all of an owner's mags (death / respawn / disconnect sweep).
func remove_owner(owner: int) -> void:
	for id in _mags.keys():
		if int(_mags[id]["owner"]) == owner:
			_mags.erase(id)
	_rl_by_owner.erase(owner)

## TTL despawn — call each tick.
func step(tick: int) -> void:
	for id in _mags.keys():
		if tick - int(_mags[id]["spawn_tick"]) >= TTL_TICKS:
			_mags.erase(id)

func for_owner(owner: int) -> Array:
	var out: Array = []
	for id in _mags:
		if int(_mags[id]["owner"]) == owner:
			out.append(_mags[id])
	return out

## Decide-to-send latch for one owner's list (ReliableList content compare + heartbeat).
func should_send(owner: int, payload: PackedByteArray, non_empty: bool, tick: int) -> bool:
	if not _rl_by_owner.has(owner):
		_rl_by_owner[owner] = ReliableList.new()
	return _rl_by_owner[owner].should_send(payload, non_empty, tick)

## Test helper — reposition a mag (used to colocate for the range/look check in tests).
func set_pos(id: int, pos: Vector3) -> void:
	if _mags.has(id):
		_mags[id]["pos"] = pos

class_name SquadManager
extends RefCounted
## Per-team squad membership. Squads of SQUAD_SIZE, never spanning teams. First member is
## the leader; on removal the next member is promoted implicitly (leader = index 0). A
## freed slot is reused before opening a new squad. See docs/specs/m3-conquest-squads.md.

const SQUAD_SIZE := 8

var _squads := {0: {}, 1: {}}   # team -> {squad_id:int -> Array[int] member ids (leader first)}
var squad_of := {}              # client_id -> squad_id

func assign(client_id: int, team: int) -> int:
	var squads: Dictionary = _squads[team]
	var sid := -1
	var ids := squads.keys()
	ids.sort()
	for k in ids:
		if squads[k].size() < SQUAD_SIZE:
			sid = k; break
	if sid == -1:
		sid = squads.size()
		squads[sid] = []
	squads[sid].append(client_id)
	squad_of[client_id] = sid
	return sid

func remove(client_id: int, team: int) -> void:
	var sid: int = squad_of.get(client_id, -1)
	if sid == -1: return
	var arr: Array = _squads[team].get(sid, [])
	arr.erase(client_id)
	squad_of.erase(client_id)

func leader_of(team: int, squad_id: int) -> int:
	var arr: Array = _squads[team].get(squad_id, [])
	return arr[0] if arr.size() > 0 else 0

func members(team: int, squad_id: int) -> Array:
	return _squads[team].get(squad_id, [])

## Move client_id into squad_id on `team`. Returns false (no-op) if the target squad is full.
## Removes the client from their current squad first; creates the target bucket if absent.
func join(client_id: int, team: int, squad_id: int) -> bool:
	if members(team, squad_id).size() >= SQUAD_SIZE:
		return false
	remove(client_id, team)
	if not _squads[team].has(squad_id):
		_squads[team][squad_id] = []
	_squads[team][squad_id].append(client_id)
	squad_of[client_id] = squad_id
	return true

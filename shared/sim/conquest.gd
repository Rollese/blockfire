class_name ConquestState
extends RefCounted
## Authoritative Conquest mode: per-point capture (neutralize-then-take, pause on contest),
## ticket pool with flag-deficit bleed + per-death cost, and win condition. Steps each
## server tick from world pawn positions. All rules live here (shared) so server authority
## is single-source. See docs/specs/m3-conquest-squads.md.

const TICKETS_START := 250
const BLEED_PER_FLAG := 1.0
const DEATH_TICKET_COST := 1
const CAP_RATE_BASE := 0.10        # per-second cap gain, single attacker (~10s/phase)
const CAP_BONUS_PER := 0.20        # extra rate fraction per additional attacker
const CAP_MAX_ATTACKERS := 8
const CAP_DECAY_RATE := 0.05       # per-second cap decay when a point is empty
const MATCH_TIME_LIMIT := 1200.0   # fail-safe; on expiry, more tickets wins

var points: Array = []             # [{id, pos:Vector3, radius, owner:int, attacker:int, cap:float}]
var tickets: Array[float] = []
var time_limit: float = MATCH_TIME_LIMIT
var match_over: bool = false
var winner: int = -1
var elapsed: float = 0.0

func _init(map: MapDef = null) -> void:
	tickets = [float(TICKETS_START), float(TICKETS_START)]
	if map == null:
		return
	for pt in map.points:
		points.append({
			"id": pt["id"], "pos": pt["pos"], "radius": pt["radius"],
			"owner": int(pt["start_owner"]), "attacker": -1, "cap": 0.0,
			"n0": 0, "n1": 0,   # team presence counts, refreshed each step() (for spawn-contest checks)
		})

func owned_count(team: int) -> int:
	var n := 0
	for pt in points:
		if pt["owner"] == team:
			n += 1
	return n

## True if an enemy of `team` currently occupies capture point `idx`. BattleBit rule: a team may
## not spawn on a point with enemies on it. Reads the presence counts cached by step().
func point_contested_by_enemy(team: int, idx: int) -> bool:
	if idx < 0 or idx >= points.size():
		return false
	var pt: Dictionary = points[idx]
	var enemy_n: int = int(pt.get("n1", 0)) if team == 0 else int(pt.get("n0", 0))
	return enemy_n > 0

func tickets_int(team: int) -> int:
	return int(ceil(tickets[team]))

func register_death(team: int) -> void:
	tickets[team] -= float(DEATH_TICKET_COST)

func nearest_capturable_index(team: int, from: Vector3) -> int:
	var best := -1
	var best_d := INF
	for i in points.size():
		if points[i]["owner"] == team:
			continue
		var d: float = from.distance_to(points[i]["pos"])
		if d < best_d:
			best_d = d; best = i
	return best

func step(dt: float, world: World) -> void:
	if match_over:
		return
	for pt in points:
		var n0 := 0
		var n1 := 0
		for id in world.pawns:
			var p: Pawn = world.pawns[id]
			if not p.alive:
				continue
			var dx: float = p.pos.x - pt["pos"].x
			var dz: float = p.pos.z - pt["pos"].z
			if dx * dx + dz * dz <= pt["radius"] * pt["radius"]:
				if p.team == 0: n0 += 1
				else: n1 += 1
		pt["n0"] = n0
		pt["n1"] = n1
		_resolve_point(pt, n0, n1, dt)
	for team in [0, 1]:
		var deficit := maxi(0, owned_count(1 - team) - owned_count(team))
		if deficit > 0:
			tickets[team] -= BLEED_PER_FLAG * float(deficit) * dt
	elapsed += dt
	if tickets[0] <= 0.0 and tickets[1] <= 0.0:
		_finish(0 if tickets[0] >= tickets[1] else 1)
	elif tickets[0] <= 0.0:
		_finish(1)
	elif tickets[1] <= 0.0:
		_finish(0)
	elif elapsed >= time_limit:
		_finish(0 if tickets[0] >= tickets[1] else 1)

func _finish(win_team: int) -> void:
	tickets[0] = maxf(tickets[0], 0.0)
	tickets[1] = maxf(tickets[1], 0.0)
	match_over = true
	winner = win_team

func _cap_rate(n: int) -> float:
	var c := mini(n, CAP_MAX_ATTACKERS)
	return CAP_RATE_BASE * (1.0 + CAP_BONUS_PER * float(c - 1))

func _resolve_point(pt: Dictionary, n0: int, n1: int, dt: float) -> void:
	var owner: int = pt["owner"]
	if n0 > 0 and n1 > 0:
		return  # contested: freeze
	if n0 == 0 and n1 == 0:
		if pt["attacker"] != -1:
			pt["cap"] = maxf(0.0, pt["cap"] - CAP_DECAY_RATE * dt)
			if pt["cap"] <= 0.0:
				pt["attacker"] = -1
		return
	var t := 0 if n0 > 0 else 1
	var n := n0 if t == 0 else n1
	if owner == t:
		pt["cap"] = 0.0
		pt["attacker"] = -1
		return
	if pt["attacker"] != t:
		pt["attacker"] = t
		pt["cap"] = 0.0
	pt["cap"] += _cap_rate(n) * dt
	if pt["cap"] >= 1.0:
		if owner != -1:
			pt["owner"] = -1      # neutralize done; same team keeps capturing next ticks
			pt["cap"] = 0.0
		else:
			pt["owner"] = t       # capture done
			pt["attacker"] = -1
			pt["cap"] = 0.0

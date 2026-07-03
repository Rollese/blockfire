class_name AiSupport
extends RefCounted
## M7.5-P3: pure support & survivability decisions. All inputs are things the bot
## legitimately knows: its own SELF_STATE, its interest snapshot, and the
## GADGET_LIST/GRENADE_FX broadcasts a human client also receives. No server state.

const MEDIC_REVIVE_RANGE := 40.0     # medics commit to distant revives
const NONMEDIC_REVIVE_RANGE := 12.0  # others only opportunistically, close by
const BAG_SEEK_HP_FRAC := 0.55
const BAG_SEEK_AMMO_FRAC := 0.34
const BAG_ARRIVE_RANGE := 2.5
const GRENADE_DANGER_RADIUS := 8.0   # matches server BLAST_PAWN_RADIUS + margin
const MINE_DANGER_RADIUS := 6.0
const GRENADE_DANGER_TICKS := 75     # fuse 45 + flight margin @30Hz
const BAG_DEPLOY_COOLDOWN_TICKS := 450   # 15s
const BAG_DEPLOY_NEEDY := 2

## downed_allies: [{id, pos, dist}] from WorldModel. Returns the chosen ally or {}.
## allies: [{id, pos, dist}] alive non-downed friendlies the bot can see; self_id = its own pawn id.
## A bot only commits to a downed ally it is the CLOSEST friendly to (ties broken by lower id) — so
## a single reviver peels off instead of the whole squad piling on (which stalled the whole fight
## the moment anyone dropped). Empty allies => no competitors => nearest-in-reach (legacy behaviour).
static func pick_revive_target(downed_allies: Array, is_medic: bool,
		allies: Array = [], self_id: int = 0) -> Dictionary:
	var reach := MEDIC_REVIVE_RANGE if is_medic else NONMEDIC_REVIVE_RANGE
	var best: Dictionary = {}
	for d in downed_allies:
		if float(d["dist"]) > reach: continue
		if not _is_closest_reviver(d, allies, self_id): continue
		if best.is_empty() or float(d["dist"]) < float(best["dist"]):
			best = d
	return best

## True if no visible friendly is closer to `downed` than I am (my dist is downed["dist"], measured
## from me). Exact ties resolve to the lower id so exactly one bot commits — never both, never neither.
static func _is_closest_reviver(downed: Dictionary, allies: Array, self_id: int) -> bool:
	var my_d := float(downed["dist"])
	var dpos: Vector3 = downed["pos"]
	for a in allies:
		var ad: float = (a["pos"] as Vector3).distance_to(dpos)
		if ad < my_d - 0.001: return false                             # a strictly-closer friendly exists
		if absf(ad - my_d) <= 0.001 and int(a["id"]) < self_id: return false   # tie -> lower id wins
	return true

static func wants_supply(hp_frac: float, ammo_frac: float) -> String:
	if hp_frac < BAG_SEEK_HP_FRAC: return "heal"
	if ammo_frac < BAG_SEEK_AMMO_FRAC: return "ammo"
	return ""

## bags: [{kind, pos, team}] (bot's GADGET_LIST mirror, friendly already filtered by caller
## or filtered here via team). Returns nearest matching bag or {}.
static func pick_supply_bag(bags: Array, me_pos: Vector3, me_team: int, kind: String) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for b in bags:
		if String(b["kind"]) != kind or int(b["team"]) != me_team: continue
		var d: float = me_pos.distance_to(b["pos"])
		if d < best_d:
			best_d = d; best = b
	return best

static func should_deploy_bag(cls: int, needy_count: int, now: int, last_deploy_tick: int) -> bool:
	if cls != Loadout.MEDIC and cls != Loadout.SUPPORT: return false
	return needy_count >= BAG_DEPLOY_NEEDY and now - last_deploy_tick >= BAG_DEPLOY_COOLDOWN_TICKS

## grenade_events: [{pos, tick}] (predicted landing spots from GRENADE_FX, stamped on receipt).
## mines: [{pos, team}]. Returns live danger zones [{pos, radius}].
static func danger_zones(grenade_events: Array, mines: Array, me_team: int, now: int) -> Array:
	var out: Array = []
	for g in grenade_events:
		if now - int(g["tick"]) <= GRENADE_DANGER_TICKS:
			out.append({"pos": g["pos"], "radius": GRENADE_DANGER_RADIUS})
	for m in mines:
		if int(m["team"]) != me_team:
			out.append({"pos": m["pos"], "radius": MINE_DANGER_RADIUS})
	return out

## Away-vector from the nearest zone the bot is inside; ZERO when clear.
static func flee_vector(me_pos: Vector3, zones: Array) -> Vector3:
	var nearest: Dictionary = {}
	var nearest_d := INF
	for z in zones:
		var d: float = me_pos.distance_to(z["pos"])
		if d <= float(z["radius"]) and d < nearest_d:
			nearest_d = d; nearest = z
	if nearest.is_empty(): return Vector3.ZERO
	var away: Vector3 = me_pos - nearest["pos"]
	away.y = 0.0
	return Vector3(0, 0, 1) if away.length() < 0.01 else away.normalized()

class_name Perception
extends RefCounted
## Builds the per-bot WorldModel from the interest snapshot. Owns short-term memory
## (decaying last-known enemy positions) and the reaction-delay gate. See docs/specs/bot-ai.md §5.

const REACTION_DELAY_TICKS := 9   # ~0.3s @30Hz; historical default — the live gate uses the
                                  # reaction_delay_ticks instance var (profile-wired, M7.5-P3 §E)
const MEMORY_DECAY_TICKS := 90    # 3s @30Hz (§11)
const REVIVE_THREAT_RANGE := 15.0    # m: an enemy this close to MY downed ally threatens the revive
const REVIVE_THREAT_PRIORITY := 0.5  # priority tag pick_target blends in (§7)
const PRESSURE_HP_REF := 50.0
const PRESSURE_DECAY := 0.97      # per-tick envelope decay: a full hit fades below the crouch
                                  # threshold (0.5) in ~0.8s and floors to 0 in ~4s

static func is_actionable(first_seen_tick: int, now: int, delay: int) -> bool:
	return now - first_seen_tick >= delay

## Returns a new memory dict with entries older than `lifetime` ticks removed.
## mem: enemy_id -> {pos:Vector3, tick:int}. Pure (§5.2 memory decay).
static func decay_memory(mem: Dictionary, now: int, lifetime: int) -> Dictionary:
	var kept := {}
	for id in mem:
		if now - int(mem[id]["tick"]) <= lifetime:
			kept[id] = mem[id]
	return kept

## Infer 0..1 combat pressure from observables: recent health drop (normalised by a
## 50 HP reference) plus an enemy currently aiming at me. Pure (§6.1).
static func infer_pressure(prev_hp: float, cur_hp: float, aimed_at: bool) -> float:
	var dmg: float = maxf(prev_hp - cur_hp, 0.0)
	var p: float = dmg / PRESSURE_HP_REF
	if aimed_at:
		p += 0.5
	return clampf(p, 0.0, 1.0)

## Pressure envelope (batch 6): the raw impulse is nonzero only on the exact tick health
## dropped, which made take_cover a 1-tick twitch oscillating with engage. A fresh impulse
## dominates; otherwise the previous pressure decays geometrically and floors to exactly 0
## so calm bots aren't stuck with an infinite tail. Pure.
static func decay_pressure(prev: float, impulse: float) -> float:
	var p: float = maxf(impulse, prev * PRESSURE_DECAY)
	return p if p >= 0.01 else 0.0

const BAG_GIVEUP_TICKS := 90       # ~3s standing ON a bag with the need unmet -> it can't help us
const BAG_BLACKLIST_TICKS := 900   # ~30s a useless bag stays ignored before we may try it again

var reaction_delay_ticks: int = REACTION_DELAY_TICKS   # per-profile gate delay, set by AiDriver
                                                        # from data/ai_tuning.json (M7.5-P3 §E)
var _first_seen: Dictionary = {}   # enemy_id -> tick first continuously seen
var _memory: Dictionary = {}        # enemy_id -> {pos, tick} last-known
var _last_hp: float = 100.0
var _pressure: float = 0.0          # decaying incoming_fire envelope (see decay_pressure)
var _bag_camp_key := ""             # pos key of the supply bag we're currently standing on
var _bag_camp_since := -1           # tick we arrived at it with the need still unmet
var _bag_blacklist: Dictionary = {} # pos key -> ignore-until tick (bags that dispensed nothing)

## Clear per-life state (see AiDriver.reset): re-arm the reaction gate, drop last-known
## memory, and start the pressure baseline from full health for the next spawn.
func reset() -> void:
	_first_seen = {}
	_memory = {}
	_last_hp = 100.0
	_pressure = 0.0
	_bag_camp_key = ""
	_bag_camp_since = -1
	_bag_blacklist = {}

static func _bag_key(pos: Vector3) -> String:
	return "%d:%d" % [roundi(pos.x), roundi(pos.z)]
## Build the WorldModel from the snapshot view. `my_id` is this bot's pawn id.
## M7.5-P3 trailing inputs (all default-empty so pre-P3 callsites are untouched):
## `net_self` = decoded SELF_STATE dict (mag/weapon/bandages…), `gadgets` = the bot's
## GADGET_LIST mirror, `grenade_events` = [{pos, tick}] landing estimates from GRENADE_FX,
## `is_medic` = bot class is MEDIC (drives revive commit range).
func build(my_id: int, view: Dictionary, _vview: Dictionary, structs: Dictionary, match_points: Array, now: int, net_self: Dictionary = {}, gadgets: Array = [], grenade_events: Array = [], is_medic: bool = false) -> WorldModel:
	var w := WorldModel.new()
	w.now_tick = now
	var me: EntityState = view.get(my_id)
	w.self_state = me
	w.me_pos = me.pos if me != null else Vector3.ZERO
	var cur_hp: float = float(me.health) if me else 100.0
	w.metadata_hp_frac = cur_hp / 100.0
	# Pressure from health-drop since last tick, held in a decaying envelope so cover-seeking
	# persists past the hit tick. `aimed_at` geometry is deferred (§6.1 follow-up), so it's
	# false for now — health loss alone drives take_cover/retreat this increment.
	_pressure = decay_pressure(_pressure, infer_pressure(_last_hp, cur_hp, false))
	w.incoming_fire = _pressure
	_last_hp = cur_hp
	var seen_now := {}
	for id in view:
		if int(id) == my_id:
			continue
		var e: EntityState = view[id]
		if me != null and e.team == me.team:
			if e.is_downed:
				w.downed_allies.append({"id": int(id), "pos": e.pos, "dist": me.pos.distance_to(e.pos)})
			elif e.alive:
				w.allies.append({"id": int(id), "pos": e.pos, "dist": me.pos.distance_to(e.pos)})
			continue
		# Downed pawns keep alive==true but are immune to weapon damage — never
		# targetable (mirrors the reflex-loop rule; shoot the reviver instead).
		if not e.alive or e.is_downed:
			continue
		var d: float = (me.pos.distance_to(e.pos) if me else 0.0)
		w.enemies.append({"id": int(id), "pos": e.pos, "stance": e.stance, "dist": d, "last_seen_tick": now, "hp_frac": float(e.health) / 100.0})
		seen_now[int(id)] = true
		if not _first_seen.has(int(id)):
			_first_seen[int(id)] = now
		_memory[int(id)] = {"pos": e.pos, "tick": now}
	for id in _first_seen.keys():
		if not seen_now.has(id) and not _memory.has(id):
			_first_seen.erase(id)
	_memory = decay_memory(_memory, now, MEMORY_DECAY_TICKS)
	# M7.5-P3 (§E): tag enemies threatening a revive — any of MY downed allies within
	# REVIVE_THREAT_RANGE of the enemy. AiCombat.pick_target already blends `priority`
	# into target scoring; this finally feeds it. Downed list is tiny, so O(E*D) is fine.
	for e in w.enemies:
		var pri := 0.0
		for da in w.downed_allies:
			if (e["pos"] as Vector3).distance_to(da["pos"]) <= REVIVE_THREAT_RANGE:
				pri = REVIVE_THREAT_PRIORITY
				break
		e["priority"] = pri
	for sid in structs:
		var cell: Vector3i = structs[sid]["cell"]
		w.cover.append(BuildGrid.world_of(cell))
	# NOTE: w.objectives is deliberately NOT filled from match_points — MATCH_STATE records carry
	# only {owner, attacker, cap}, no position, so the old fill stamped every objective at the
	# origin (garbage for any consumer). Objective POSITIONS come from the driver's MapDef
	# (`_objective_pos`); wire owner+pos together here when a consumer actually needs them.
	# M7.5-P3 Task 6: support & survivability fields from the bot's mirrors.
	var my_team: int = int(me.team) if me != null else -1
	# Pass visible friendlies + my id so only the closest bot commits to each revive (no squad pile-on).
	w.revive_target = AiSupport.pick_revive_target(w.downed_allies, is_medic, w.allies, my_id)
	# Ammo fraction from SELF_STATE mag vs the current weapon's mag size (Weapon.get_def
	# falls back to the AR def for unknown ids, so the division is always sane).
	var ammo_frac := 1.0
	if not net_self.is_empty():
		var mag_size := maxf(1.0, float(Weapon.get_def(int(net_self.get("weapon", 0))).get("mag_size", 30)))
		ammo_frac = clampf(float(int(net_self.get("mag", 0))) / mag_size, 0.0, 1.0)
	w.supply_kind = AiSupport.wants_supply(w.metadata_hp_frac, ammo_frac)
	# The GADGET_LIST wire carries kind/pos only — no owner team and no heal-vs-ammo bag
	# distinction (a human client gets exactly the same). Adapt fairly: every mine is treated
	# as dangerous (team -1 never matches mine, so sidestepping a friendly claymore too —
	# harmless), and every bag is a candidate for the wanted supply kind (standing on an
	# enemy/wrong-kind bag just dispenses nothing; the bot re-scores and moves on).
	var bags: Array = []
	var mines: Array = []
	for g in gadgets:
		match int(g.get("kind", -1)):
			GadgetList.BAG:
				# Skip bags that already proved useless (see the no-progress tracker below) —
				# without this, "re-scores and moves on" re-picked the SAME nearest bag forever.
				if int(_bag_blacklist.get(_bag_key(g["pos"]), -1)) <= now:
					bags.append({"kind": w.supply_kind, "pos": g["pos"], "team": my_team})
			GadgetList.MINE:
				mines.append({"pos": g["pos"], "team": -1})
	if w.supply_kind != "":
		w.supply_bag = AiSupport.pick_supply_bag(bags, w.me_pos, my_team, w.supply_kind)
	# No-progress tracker: the GADGET_LIST wire has no team and no heal-vs-ammo kind, so a picked
	# bag can be an enemy bag or the wrong kind — the bot would stand on it forever with seek_supply
	# outranking everything. If we've stood ON the chosen bag for BAG_GIVEUP_TICKS and the need is
	# still unmet (supply_kind unchanged), blacklist that bag and re-pick elsewhere.
	if not w.supply_bag.is_empty() and w.me_pos.distance_to(w.supply_bag["pos"]) <= AiSupport.BAG_ARRIVE_RANGE + 0.5:
		var ck := _bag_key(w.supply_bag["pos"])
		if ck != _bag_camp_key:
			_bag_camp_key = ck
			_bag_camp_since = now
		elif now - _bag_camp_since >= BAG_GIVEUP_TICKS:
			_bag_blacklist[ck] = now + BAG_BLACKLIST_TICKS
			w.supply_bag = AiSupport.pick_supply_bag(bags.filter(
				func(b): return _bag_key(b["pos"]) != ck), w.me_pos, my_team, w.supply_kind)
			_bag_camp_key = ""
			_bag_camp_since = -1
	else:
		_bag_camp_key = ""
		_bag_camp_since = -1
	w.danger_zones = AiSupport.danger_zones(grenade_events, mines, my_team, now)
	return w
## Reaction gate for a currently-visible enemy id at time `now`. Uses the per-profile
## instance delay (recruit 15 .. elite 4), wired from ai_tuning.json by AiDriver (§E).
func actionable(enemy_id: int, now: int) -> bool:
	if not _first_seen.has(enemy_id):
		return false
	return is_actionable(int(_first_seen[enemy_id]), now, reaction_delay_ticks)

## Most recent last-known enemy memory entry ({pos, tick}) or {} when memory is empty /
## fully decayed. The suppress behaviour aims here when no enemy is visible (§E: the
## _memory store is finally read, not just written).
func last_known() -> Dictionary:
	var best: Dictionary = {}
	for id in _memory:
		if best.is_empty() or int(_memory[id]["tick"]) > int(best["tick"]):
			best = _memory[id]
	return best

class_name HudModel
extends RefCounted
## Pure HUD data builder. build(ctx) returns a plain Dictionary the view draws. No nodes, no
## drawing — headless-testable. ctx keys are filled in by client_main each frame.

const LOW_AMMO_FRAC := 0.34
const KILLFEED_TTL := 6.0
const DAMAGE_TTL := 1.5
const BLIND_FULL_TICKS := 45.0   # remaining-blind ticks at/above which the flash white-out is opaque
# C4: the FX onset was 0.25 ramping to full at 1.0, so brief near-miss suppression (which spikes to
# ~0.15–0.4 then decays 0.04/tick) never rendered a visible veil. Onset below the gameplay spread
# threshold, full at a realistic sustained-fire level, so being shot at reads on-screen.
const SUPPRESS_FX_THRESHOLD := 0.10   # veil starts just below one dead-on near-miss (≈0.15)
const SUPPRESS_FX_FULL := 0.35        # veil is full at a couple of near-misses / brief sustained fire

## Flashbang white-out opacity (0..1) from the SELF_STATE remaining-blind-ticks byte (M5.5-P3).
## Saturated white while ≥ BLIND_FULL_TICKS remain, then a linear fade over the final tail — so a
## flash holds full white for ~1.5s and clears over ~1.5s (FLASH_BLIND_TICKS=90 @30Hz).
static func blind_intensity(blind_ticks: int) -> float:
	return clampf(float(blind_ticks) / BLIND_FULL_TICKS, 0.0, 1.0)

## Suppression screen-FX strength (0..1) from the SELF_STATE own-suppression scalar (M5.5-P2).
## Zero below the threshold (so audio + visual suppression onset align and idle shows nothing), then a
## pow(0.7) ramp to full. A6: smoothstep buried a single near-miss (0.15) down near zero, so being shot
## at was invisible; the concave low-end curve makes even one near-miss read while sustained fire caps.
## The client also peak-holds this (see client_main _supp_fx) so a spike lingers long enough to see.
static func suppression_intensity(suppression: float) -> float:
	if suppression < SUPPRESS_FX_THRESHOLD:
		return 0.0
	var t := clampf((suppression - SUPPRESS_FX_THRESHOLD) / (SUPPRESS_FX_FULL - SUPPRESS_FX_THRESHOLD), 0.0, 1.0)
	return pow(t, 0.7)
var _killfeed: Array = []   # [{killer,victim,headshot,weapon,t}]
var _capture_feed: Array = []   # [{label:String, status:int, t:float}] — capture-point announcements
const CAPTURE_FEED_TTL := 4.0   # seconds a capture banner lingers
var _damages: Array = []   # [{bearing,amount,t}]
var _throwable_active: int = 0
var _death_info = null

func push_kill(ev: Dictionary, now: float) -> void:
	_killfeed.append({"killer": int(ev["killer"]), "victim": int(ev["victim"]),
		"headshot": bool(ev["headshot"]), "weapon": int(ev["weapon"]), "t": now})

func _killfeed_current(ctx: Dictionary) -> Array:
	var now := float(ctx.get("now", 0.0))
	# Resolve ids -> names + friend/foe from the roster, so the feed reads "Alice -> Bob" not "1 -> 2".
	var by_id: Dictionary = {}
	for rw: Dictionary in ctx.get("roster", []):
		by_id[int(rw["id"])] = rw
	var self_id := int(ctx.get("self_id", 0))
	var my_team := int(by_id[self_id]["team"]) if by_id.has(self_id) else -1
	var raw_kept: Array = []
	var out: Array = []
	for e in _killfeed:
		if now - e["t"] > KILLFEED_TTL:
			continue
		raw_kept.append(e)
		out.append({
			"killer_name": _roster_name(by_id, int(e["killer"])),
			"victim_name": _roster_name(by_id, int(e["victim"])),
			"killer_friendly": _roster_friendly(by_id, int(e["killer"]), my_team),
			"victim_friendly": _roster_friendly(by_id, int(e["victim"]), my_team),
			"headshot": bool(e.get("headshot", false)),
		})
	_killfeed = raw_kept
	return out

static func _roster_name(by_id: Dictionary, id: int) -> String:
	return String(by_id[id]["name"]) if by_id.has(id) else "#%d" % id

static func _roster_friendly(by_id: Dictionary, id: int, my_team: int) -> bool:
	return my_team >= 0 and by_id.has(id) and int(by_id[id]["team"]) == my_team

## Push capture-point announcements (each {label, status} from CaptureAnnounce.diff) to the banner feed.
func push_capture_events(events: Array, now: float) -> void:
	for ev: Dictionary in events:
		_capture_feed.append({"label": String(ev["label"]), "status": int(ev["status"]), "t": now})

func _capture_feed_current(ctx: Dictionary) -> Array:
	var now := float(ctx.get("now", 0.0))
	var kept: Array = []
	for e in _capture_feed:
		if now - e["t"] <= CAPTURE_FEED_TTL:
			e["age"] = now - e["t"]
			kept.append(e)
	_capture_feed = kept
	return kept

func push_damage(world_bearing: float, amount: int, now: float) -> void:
	_damages.append({"bearing": world_bearing, "amount": amount, "t": now})

func _damage(ctx: Dictionary) -> Dictionary:
	var now: float = float(ctx.get("now", 0.0))
	var yaw: float = float(ctx.get("self_yaw", 0.0))
	var arcs: Array = []
	var vignette: float = 0.0
	var kept: Array = []
	for d in _damages:
		var age: float = now - d["t"]
		if age > DAMAGE_TTL:
			continue
		kept.append(d)
		var fade: float = 1.0 - age / DAMAGE_TTL
		# Camera-relative (view bearing = sim-yaw + PI), matching the compass convention.
		arcs.append({"rel_bearing": wrapf((yaw + PI) - d["bearing"], -PI, PI), "fade": fade})
		vignette = maxf(vignette, fade * clampf(float(d["amount"]) / 50.0, 0.0, 1.0))
	_damages = kept
	return {"arcs": arcs, "vignette": vignette}

const GRENADE_DANGER_RADIUS := 7.0   # m — a live grenade within this of the eye raises the warning

## Directional warning for the nearest live grenade (local + remote, from the renderer's cosmetic
## pool) within GRENADE_DANGER_RADIUS of the eye. Same bearing convention as the compass/damage arcs.
## Returns {rel_bearing, proximity} or {} when nothing is close. Pure.
func _grenade_danger(ctx: Dictionary):
	var grens: Array = ctx.get("grenades", [])
	if grens.is_empty():
		return {}
	var eye: Vector3 = ctx.get("self_eye", ctx.get("self_pos", Vector3.ZERO))
	var view := wrapf(float(ctx.get("self_yaw", 0.0)) + PI, -PI, PI)
	var best := GRENADE_DANGER_RADIUS + 1.0
	var best_pos: Variant = null
	for gp: Vector3 in grens:
		var dd := eye.distance_to(gp)
		if dd <= GRENADE_DANGER_RADIUS and dd < best:
			best = dd
			best_pos = gp
	if best_pos == null:
		return {}
	var d: Vector3 = (best_pos as Vector3) - eye
	var world_bearing := atan2(d.x, d.z)
	return {"rel_bearing": wrapf(view - world_bearing, -PI, PI),
		"proximity": clampf(1.0 - best / GRENADE_DANGER_RADIUS, 0.0, 1.0)}

func build(ctx: Dictionary) -> Dictionary:
	var dmg := _damage(ctx)
	return {"ammo": _ammo(ctx), "compass": _compass(ctx), "tickets": _tickets(ctx), "capture": _capture(ctx), "killfeed": _killfeed_current(ctx), "damage_arcs": dmg["arcs"], "vignette": dmg["vignette"], "scoreboard": _scoreboard(ctx), "squad_roster": _squad_roster(ctx), "interaction_prompt": _interaction_prompt(ctx), "throwables": _throwables(ctx), "death_recap": _death_recap(ctx), "grenade_danger": _grenade_danger(ctx), "capture_feed": _capture_feed_current(ctx), "repair_heat": _repair_heat(ctx), "throw_charge": _throw_charge(ctx), "stamina": _stamina(ctx)}

## C3 grenade hold-to-charge: a 0..1 throw-strength meter, shown only while charging.
func _throw_charge(ctx: Dictionary) -> Dictionary:
	var c := clampf(float(ctx.get("throw_charge", 0.0)), 0.0, 1.0)
	return {"visible": c > 0.0, "charge": c}

## Stamina bar: a slim bottom-centre readout that appears only when stamina is spent (below full),
## so the player can see why jump/sprint gate out (there is otherwise no stamina UI). Pure — reads
## the predicted stamina fraction from ctx.
func _stamina(ctx: Dictionary) -> Dictionary:
	var frac := clampf(float(ctx.get("stamina_frac", 1.0)), 0.0, 1.0)
	return {"visible": frac < 0.999, "frac": frac}

## Engineer repair-tool heat gauge. Visible only while heating or in the overheat-lockout cooldown
## (so it never shows for non-engineers). `overheated` drives the red lockout look; the beam is
## disabled until the cooldown drains. Pure — reads the SELF_STATE fractions from ctx.
func _repair_heat(ctx: Dictionary) -> Dictionary:
	var heat := clampf(float(ctx.get("repair_heat", 0.0)), 0.0, 1.0)
	var cooldown := clampf(float(ctx.get("repair_cooldown", 0.0)), 0.0, 1.0)
	var overheated := cooldown > 0.0
	return {"visible": heat > 0.0 or overheated, "heat": heat, "cooldown": cooldown, "overheated": overheated}

func cycle_throwable(count: int) -> void:
	if count <= 0:
		_throwable_active = 0
		return
	_throwable_active = (_throwable_active + 1) % count

func _throwables(ctx: Dictionary) -> Dictionary:
	var list: Array = ctx.get("throwables", [])
	if not list.is_empty() and _throwable_active >= list.size():
		_throwable_active = 0
	return {"list": list, "active": _throwable_active}

func _compass(ctx: Dictionary) -> Dictionary:
	var yaw := float(ctx.get("self_yaw", 0.0))
	# The camera looks along sim-yaw + PI (Godot cameras face -Z; the sim's forward is +Z), so
	# the compass "ahead" (rel_bearing 0) must be the camera's view bearing, not the raw sim yaw.
	var view := wrapf(yaw + PI, -PI, PI)
	var sp: Vector3 = ctx.get("self_pos", Vector3.ZERO)
	var markers: Array = []
	for o in ctx.get("objectives", []):
		var d: Vector3 = o["pos"] - sp
		var world_bearing := atan2(d.x, d.z)
		markers.append({"rel_bearing": wrapf(view - world_bearing, -PI, PI), "owner": int(o["owner"]),
			"label": String(o.get("label", ""))})
	return {"heading": view, "markers": markers, "my_team": int(ctx.get("self_team", -1))}

## Top-centre match-status readout (BattleBit-style): both teams' ticket counts (viewer-relative,
## ours vs enemy), the match timer (MM:SS from `elapsed`), and a WINNING/LOSING/TIED word for the
## viewer. Pure — reads the decoded match_state + the viewer's team. Falls back to the roster if
## `self_team` isn't supplied in ctx.
func _tickets(ctx: Dictionary) -> Dictionary:
	var ms: Dictionary = ctx.get("match_state", {})
	var tk: Array = ms.get("tickets", [0, 0])
	var t0: int = int(tk[0]) if tk.size() > 0 else 0
	var t1: int = int(tk[1]) if tk.size() > 1 else 0
	var my_team := int(ctx.get("self_team", -1))
	if my_team < 0:
		my_team = _self_team(ctx)
	# Viewer-relative split: team 1 sees its own count as "mine". Neutral/unknown (-1) keeps t0 as mine.
	var mine := t1 if my_team == 1 else t0
	var enemy := t0 if my_team == 1 else t1
	return {"my_tickets": mine, "enemy_tickets": enemy, "t0": t0, "t1": t1, "my_team": my_team,
		"timer_str": format_timer(int(ms.get("elapsed", 0))), "status": ticket_status(mine, enemy)}

## MM:SS from a whole-second elapsed count. Pure; clamps negatives to 0.
static func format_timer(elapsed: int) -> String:
	var e: int = maxi(elapsed, 0)
	return "%02d:%02d" % [e / 60, e % 60]

## Viewer's standing from the two ticket counts: more tickets = WINNING, fewer = LOSING, equal = TIED.
static func ticket_status(mine: int, enemy: int) -> String:
	if mine > enemy: return "WINNING"
	if mine < enemy: return "LOSING"
	return "TIED"

func _capture(ctx: Dictionary):
	var ms: Dictionary = ctx.get("match_state", {})
	var pts: Array = ms.get("points", [])
	var positions: Array = ctx.get("point_positions", [])
	var radii: Array = ctx.get("point_radii", [])
	var sp: Vector3 = ctx.get("self_pos", Vector3.ZERO)
	var my_team := _self_team(ctx)
	for i in mini(pts.size(), positions.size()):
		# TRUE per-point radius (matches the ground ring + server capture); fall back to 8 m only if
		# radii weren't supplied.
		var radius: float = float(radii[i]) if i < radii.size() else 8.0
		if sp.distance_to(positions[i]) <= radius:
			return {"index": i, "cap": float(pts[i]["cap"]), "owner": int(pts[i]["owner"]),
				"attacker": int(pts[i]["attacker"]), "my_team": my_team}
	return null

## Local player's team from the roster (like the killfeed), or -1 if unknown. Used to render capture
## ownership relative to the viewer (ours / enemy / neutral).
static func _self_team(ctx: Dictionary) -> int:
	var self_id := int(ctx.get("self_id", 0))
	for rw: Dictionary in ctx.get("roster", []):
		if int(rw.get("id", -1)) == self_id:
			return int(rw.get("team", -1))
	return -1

func _ammo(ctx: Dictionary) -> Dictionary:
	var wp: WeaponPredictor = ctx.get("weapon_predictor") as WeaponPredictor
	if wp == null:
		return {"mag": 0, "reserve": 0, "reloading": false, "low": false}
	# RPG: the readout is the rocket pool (kind 100 in throwables), not a hit-scan magazine.
	if int(wp.weapon) == Weapon.RPG:
		var rockets := 0
		for t in ctx.get("throwables", []):
			if int(t.get("kind", -1)) == 100:
				rockets = int(t.get("count", 0)); break
		return {"mag": rockets, "reloading": wp.reloading, "reload_remaining": wp.reload_remaining(int(ctx.get("tick", 0))), "low": rockets <= 1, "is_rpg": true, "fire_mode": ""}
	var mag_size := int(Weapon.get_def(wp.weapon)["mag_size"])
	return {
		"mag": wp.mag,
		"reserve": wp.reserve,   # reserve-ammo economy (M17): spare-bullet pool shown after the mag
		"reloading": wp.reloading,
		"reload_remaining": wp.reload_remaining(int(ctx.get("tick", 0))),
		"low": wp.mag <= int(ceil(mag_size * LOW_AMMO_FRAC)),
		"is_rpg": false,
		"fire_mode": Weapon.mode_name(wp.fire_mode),   # AUTO/SEMI/BURST glyph for the HUD
	}

func _interaction_prompt(ctx: Dictionary):
	# M19 P4: manning an LMG nest -> the F prompt becomes "dismount" (top priority, like exit_vehicle).
	var mounted := int(ctx.get("mounted_nest", 0))
	if mounted != 0:
		return {"action": "dismount_nest", "target": mounted}
	# Already seated in a vehicle -> the F prompt becomes "exit" (takes priority over revive/enter).
	var in_veh := int(ctx.get("in_vehicle", -1))
	if in_veh >= 0:
		return {"action": "exit_vehicle", "target": in_veh}
	var mates: Array = ctx.get("downed_mates", [])
	if not mates.is_empty():
		var best: Dictionary = mates[0]
		for mt in mates:
			if float(mt["dist"]) < float(best["dist"]):
				best = mt
		return {"action": "revive", "target": int(best["id"])}
	# M16: bandage a standing-bleeding mate in range (a world target, so above enter/self-bandage).
	var bmates: Array = ctx.get("bleeding_mates", [])
	if not bmates.is_empty():
		var bb: Dictionary = bmates[0]
		for bm in bmates:
			if float(bm["dist"]) < float(bb["dist"]):
				bb = bm
		return {"action": "bandage", "target": int(bb["id"])}
	var veh: Array = ctx.get("vehicles_near", [])
	if not veh.is_empty():
		var bv: Dictionary = veh[0]
		for v in veh:
			if float(v["dist"]) < float(bv["dist"]):
				bv = v
		return {"action": "enter_vehicle", "target": int(bv["vid"]), "seat": int(bv["seat"])}
	# M19 P4: a friendly, unoccupied LMG nest in mount range -> offer to man it (below vehicles).
	var nests: Array = ctx.get("nests_near", [])
	if not nests.is_empty():
		var bn: Dictionary = nests[0]
		for n in nests:
			if float(n["dist"]) < float(bn["dist"]):
				bn = n
		return {"action": "mount_nest", "target": int(bn["id"])}
	# M16: no world prompt applies — offer self-bandage while you are standing-bleeding (lowest priority).
	if bool(ctx.get("am_bleeding", false)):
		return {"action": "self_bandage", "target": int(ctx.get("self_id", 0))}
	return null

func _squad_roster(ctx: Dictionary) -> Array:
	var roster: Array = ctx.get("roster", [])
	var self_id := int(ctx.get("self_id", 0))
	var entities: Dictionary = ctx.get("entities", {})
	var my_team := -1
	var my_squad := -1
	for rw in roster:
		if int(rw["id"]) == self_id:
			my_team = int(rw["team"]); my_squad = int(rw["squad"]); break
	var out: Array = []
	if my_team < 0:
		return out
	for rw in roster:
		if int(rw["id"]) == self_id or int(rw["team"]) != my_team or int(rw["squad"]) != my_squad:
			continue
		var e: Dictionary = entities.get(int(rw["id"]), {})
		var status := "dead"
		if not e.is_empty() and bool(e.get("alive", false)):
			status = "downed" if bool(e.get("is_downed", false)) else "alive"
		out.append({"id": int(rw["id"]), "name": String(rw["name"]), "status": status})
	return out

func set_death_info(info: Dictionary) -> void:
	_death_info = info

func clear_death_info() -> void:
	_death_info = null

func _name_for(roster: Array, id: int) -> String:
	for rw in roster:
		if int(rw["id"]) == id:
			return String(rw["name"])
	return "#%d" % id

func _death_recap(ctx: Dictionary):
	if _death_info == null:
		return null
	var roster: Array = ctx.get("roster", [])
	var attackers: Array = []
	for a in _death_info["attackers"]:
		attackers.append({"name": _name_for(roster, int(a["id"])), "dmg": int(a["dmg"])})
	return {
		"killer_name": _name_for(roster, int(_death_info["killer"])),
		"weapon": int(_death_info["weapon"]),
		"distance": float(_death_info["distance"]),
		"killer_hp": int(_death_info["killer_hp"]),
		"attackers": attackers,
	}

func _scoreboard(ctx: Dictionary) -> Dictionary:
	var roster: Array = ctx.get("roster", [])
	var ms: Dictionary = ctx.get("match_state", {})
	var tickets: Array = ms.get("tickets", [0, 0])
	var teams: Array = []
	for t in 2:
		var rows: Array = []
		for rw in roster:
			if int(rw["team"]) == t:
				rows.append(rw)
		rows.sort_custom(func(a, b):
			if int(a["score"]) != int(b["score"]):
				return int(a["score"]) > int(b["score"])
			return String(a["name"]) < String(b["name"]))
		teams.append({"team": t, "rows": rows, "tickets": int(tickets[t]) if t < tickets.size() else 0})
	return {"teams": teams}

class_name HudModel
extends RefCounted
## Pure HUD data builder. build(ctx) returns a plain Dictionary the view draws. No nodes, no
## drawing — headless-testable. ctx keys are filled in by client_main each frame.

const LOW_AMMO_FRAC := 0.34
const KILLFEED_TTL := 6.0
const DAMAGE_TTL := 1.5
const BLIND_FULL_TICKS := 45.0   # remaining-blind ticks at/above which the flash white-out is opaque
const SUPPRESS_FX_THRESHOLD := 0.25   # mirrors shared/sim/suppress.gd SUPPRESS_THRESHOLD (audio + visual onset align)

## Flashbang white-out opacity (0..1) from the SELF_STATE remaining-blind-ticks byte (M5.5-P3).
## Saturated white while ≥ BLIND_FULL_TICKS remain, then a linear fade over the final tail — so a
## flash holds full white for ~1.5s and clears over ~1.5s (FLASH_BLIND_TICKS=90 @30Hz).
static func blind_intensity(blind_ticks: int) -> float:
	return clampf(float(blind_ticks) / BLIND_FULL_TICKS, 0.0, 1.0)

## Suppression screen-FX strength (0..1) from the SELF_STATE own-suppression scalar (M5.5-P2).
## Zero below the threshold (so audio + visual suppression onset align and idle shows nothing),
## then a smoothstep ramp to full — same shaping as the audio duck/cutoff (client/audio/audio_mix.gd).
static func suppression_intensity(suppression: float) -> float:
	if suppression < SUPPRESS_FX_THRESHOLD:
		return 0.0
	return smoothstep(SUPPRESS_FX_THRESHOLD, 1.0, clampf(suppression, 0.0, 1.0))
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
	return {"ammo": _ammo(ctx), "compass": _compass(ctx), "tickets": _tickets(ctx), "capture": _capture(ctx), "killfeed": _killfeed_current(ctx), "damage_arcs": dmg["arcs"], "vignette": dmg["vignette"], "scoreboard": _scoreboard(ctx), "squad_roster": _squad_roster(ctx), "interaction_prompt": _interaction_prompt(ctx), "throwables": _throwables(ctx), "death_recap": _death_recap(ctx), "grenade_danger": _grenade_danger(ctx), "capture_feed": _capture_feed_current(ctx)}

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
		markers.append({"rel_bearing": wrapf(view - world_bearing, -PI, PI), "owner": int(o["owner"])})
	return {"heading": view, "markers": markers}

func _tickets(ctx: Dictionary) -> Array:
	var ms: Dictionary = ctx.get("match_state", {})
	return ms.get("tickets", [0, 0])

func _capture(ctx: Dictionary):
	var ms: Dictionary = ctx.get("match_state", {})
	var pts: Array = ms.get("points", [])
	var positions: Array = ctx.get("point_positions", [])
	var sp: Vector3 = ctx.get("self_pos", Vector3.ZERO)
	var radius := float(ctx.get("capture_radius", 8.0))
	for i in mini(pts.size(), positions.size()):
		if sp.distance_to(positions[i]) <= radius:
			return {"index": i, "cap": float(pts[i]["cap"]), "owner": int(pts[i]["owner"]),
				"attacker": int(pts[i]["attacker"])}
	return null

func _ammo(ctx: Dictionary) -> Dictionary:
	var wp: WeaponPredictor = ctx.get("weapon_predictor") as WeaponPredictor
	if wp == null:
		return {"mag": 0, "reloading": false, "low": false}
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
		"reloading": wp.reloading,
		"reload_remaining": wp.reload_remaining(int(ctx.get("tick", 0))),
		"low": wp.mag <= int(ceil(mag_size * LOW_AMMO_FRAC)),
		"is_rpg": false,
		"fire_mode": Weapon.mode_name(wp.fire_mode),   # AUTO/SEMI/BURST glyph for the HUD
	}

func _interaction_prompt(ctx: Dictionary):
	var mates: Array = ctx.get("downed_mates", [])
	if not mates.is_empty():
		var best: Dictionary = mates[0]
		for mt in mates:
			if float(mt["dist"]) < float(best["dist"]):
				best = mt
		return {"action": "revive", "target": int(best["id"])}
	var veh: Array = ctx.get("vehicles_near", [])
	if not veh.is_empty():
		var bv: Dictionary = veh[0]
		for v in veh:
			if float(v["dist"]) < float(bv["dist"]):
				bv = v
		return {"action": "enter_vehicle", "target": int(bv["vid"]), "seat": int(bv["seat"])}
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

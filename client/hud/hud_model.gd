class_name HudModel
extends RefCounted
## Pure HUD data builder. build(ctx) returns a plain Dictionary the view draws. No nodes, no
## drawing — headless-testable. ctx keys are filled in by client_main each frame.

const LOW_AMMO_FRAC := 0.34
const KILLFEED_TTL := 6.0
const DAMAGE_TTL := 1.5
var _killfeed: Array = []   # [{killer,victim,headshot,weapon,t}]
var _damages: Array = []   # [{bearing,amount,t}]

func push_kill(ev: Dictionary, now: float) -> void:
	_killfeed.append({"killer": int(ev["killer"]), "victim": int(ev["victim"]),
		"headshot": bool(ev["headshot"]), "weapon": int(ev["weapon"]), "t": now})

func _killfeed_current(ctx: Dictionary) -> Array:
	var now := float(ctx.get("now", 0.0))
	var kept: Array = []
	for e in _killfeed:
		if now - e["t"] <= KILLFEED_TTL:
			kept.append(e)
	_killfeed = kept
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
		arcs.append({"rel_bearing": wrapf(d["bearing"] - yaw, -PI, PI), "fade": fade})
		vignette = maxf(vignette, fade * clampf(float(d["amount"]) / 50.0, 0.0, 1.0))
	_damages = kept
	return {"arcs": arcs, "vignette": vignette}

func build(ctx: Dictionary) -> Dictionary:
	var dmg := _damage(ctx)
	return {"ammo": _ammo(ctx), "compass": _compass(ctx), "tickets": _tickets(ctx), "capture": _capture(ctx), "killfeed": _killfeed_current(ctx), "damage_arcs": dmg["arcs"], "vignette": dmg["vignette"]}

func _compass(ctx: Dictionary) -> Dictionary:
	var yaw := float(ctx.get("self_yaw", 0.0))
	var sp: Vector3 = ctx.get("self_pos", Vector3.ZERO)
	var markers: Array = []
	for o in ctx.get("objectives", []):
		var d: Vector3 = o["pos"] - sp
		var world_bearing := atan2(d.x, d.z)
		markers.append({"rel_bearing": wrapf(world_bearing - yaw, -PI, PI), "owner": int(o["owner"])})
	return {"heading": wrapf(yaw, -PI, PI), "markers": markers}

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
	var mag_size := int(Weapon.get_def(wp.weapon)["mag_size"])
	return {
		"mag": wp.mag,
		"reloading": wp.reloading,
		"reload_remaining": wp.reload_remaining(int(ctx.get("tick", 0))),
		"low": wp.mag <= int(ceil(mag_size * LOW_AMMO_FRAC)),
	}

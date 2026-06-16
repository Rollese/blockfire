class_name HudModel
extends RefCounted
## Pure HUD data builder. build(ctx) returns a plain Dictionary the view draws. No nodes, no
## drawing — headless-testable. ctx keys are filled in by client_main each frame.

const LOW_AMMO_FRAC := 0.34

func build(ctx: Dictionary) -> Dictionary:
	return {"ammo": _ammo(ctx), "compass": _compass(ctx)}

func _compass(ctx: Dictionary) -> Dictionary:
	var yaw := float(ctx.get("self_yaw", 0.0))
	var sp: Vector3 = ctx.get("self_pos", Vector3.ZERO)
	var markers: Array = []
	for o in ctx.get("objectives", []):
		var d: Vector3 = o["pos"] - sp
		var world_bearing := atan2(d.x, d.z)
		markers.append({"rel_bearing": wrapf(world_bearing - yaw, -PI, PI), "owner": int(o["owner"])})
	return {"heading": wrapf(yaw, -PI, PI), "markers": markers}

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

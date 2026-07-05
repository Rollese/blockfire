class_name FxPool
extends Node3D
## Transient one-shot FX, physically moved out of world_renderer (batch 5 D2, owner-requested):
## cosmetic rockets, thrown grenades, smoke/impact puffs, explosion fireball cores and debris —
## each an array pool with spawn/age and an oldest-evicted cap (_pool_push). Mounted as a child
## of the renderer, so spawned nodes live under it; the muzzle-flash and casing pools plus the
## `impact` signal stay on the renderer (back-ref `r`).

var r   # WorldRenderer back-ref (owner/parent)


func _init(renderer) -> void:
	r = renderer


## Advance every pool one frame (called from the renderer update loop).
func age_all(now: float, render_delta: float) -> void:
	age_rockets(now, render_delta)
	age_blasts(now)
	age_debris(now, render_delta)
	age_puffs(now)
	age_thrown(now, render_delta)


## Struct-FX seam: brick debris built by the renderer joins the shared debris pool.
func push_debris(node: Node3D, vel: Vector3, die: float) -> void:
	_pool_push(debris, {"node": node, "vel": vel, "die": die}, MAX_DEBRIS)


# RPG rocket cosmetics — a launched rocket (local shooter feedback + replicated ROCKET_FX) flies the
# shared Grenade ballistic arc so it tracks where the server's real rocket goes, trailing smoke and
# popping a puff on impact. Presentation-only; the server owns the actual blast.
const ROCKET_SPEED := 150.0       # MUST match data/gadgets.json rpg rocket_speed
const ROCKET_LIFETIME := 5.0      # s safety cap before a cosmetic rocket self-despawns
const ROCKET_TRAIL_DT := 0.03     # s between trail puffs
# Transient-FX pool caps: TTLs normally drain these far below the caps; the caps only bite in
# pathological bursts (128p destruction fights), where the OLDEST effect is evicted first.
const MAX_ROCKETS := 64
const MAX_THROWN := 64
const MAX_PUFFS := 256
const MAX_BLASTS := 32
const MAX_DEBRIS := 384
var rockets: Array = []          # [{node: Node3D, vel: Vector3, die: float, next_puff: float}]
# thrown-grenade cosmetics (M7, view-only): the local thrower sees their own frag/smoke fly the
# shared Grenade ballistic arc (matching the server's eye-origin + launch_velocity) and vanish on
# ground contact or at the 1.5 s fuse — the DETONATION / SMOKE_DEPLOYED event then plays the effect.
const GRENADE_FUSE := 1.5         # s — MUST match server GRENADE_FUSE_TICKS (45 @ 30 Hz)
const GRENADE_TRAIL_DT := 0.05    # s between a smoke grenade's faint trail puffs
var thrown: Array = []           # [{node:Node3D, vel:Vector3, die:float, kind:int, next_trail:float}]
var puffs: Array = []            # [{node, mat, die, ttl}] — smoke trail + impact puffs
var blasts: Array = []           # [{node, mat, born, die, ttl, s0, s1, color}] — explosion fireball cores
var debris: Array = []           # [{node, vel, die}] — explosion debris chunks


func fire_rocket(origin: Vector3, dir: Vector3, now: float) -> void:
	var d := dir.normalized()
	if d.length() < 0.001:
		return
	var node := make_rocket()
	var up := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	node.global_transform = Transform3D(Basis.looking_at(d, up), origin)
	add_child(node)
	r._spawn_flash(origin, d, now)   # launch flash (muzzle-flash pool stays on the renderer)
	_pool_push(rockets, {"node": node, "vel": d * ROCKET_SPEED, "die": now + ROCKET_LIFETIME, "next_puff": now}, MAX_ROCKETS)


## One factory for the unshaded FX material recipe that was hand-rolled ~12x (tracers,
## puffs, support beams, blast cores, zone rings…). Emission defaults stay at the engine
## defaults (BLACK / 1.0) because pool materials get their colour assigned per frame.
static func fx_material(albedo: Color, alpha := false, emissive := false,
		emission := Color.BLACK, energy := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if alpha:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emissive:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = energy
	return m


## Append a transient-FX entry, evicting (freeing) the oldest past `cap`. Every pool entry
## carries its scene node under "node".
func _pool_push(pool: Array, entry: Dictionary, cap: int) -> void:
	pool.append(entry)
	while pool.size() > cap:
		var old: Dictionary = pool.pop_front()
		var n = old.get("node")
		if n is Node and is_instance_valid(n):
			(n as Node).free()   # immediate: the pool entry is the only reference to these one-shots


func age_rockets(now: float, delta: float) -> void:
	if not rockets.is_empty():
		var live: Array = []
		for r: Dictionary in rockets:
			var node: Node3D = r["node"]
			var s := Grenade.integrate(node.position, r["vel"], delta)
			var npos: Vector3 = s["pos"]
			var nvel: Vector3 = s["vel"]
			if now >= float(r["next_puff"]):
				spawn_puff(node.position, 0.4, 0.6, now)   # trail
				r["next_puff"] = now + ROCKET_TRAIL_DT
			if now >= float(r["die"]) or npos.y <= 0.0:
				if npos.y < 0.0:
					npos.y = 0.0
				spawn_puff(npos, 2.4, 0.55, now)           # impact puff
				node.queue_free()
				continue
			var up := Vector3.UP if absf(nvel.normalized().dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
			node.global_transform = Transform3D(Basis.looking_at(nvel.normalized(), up), npos)
			r["vel"] = nvel
			live.append(r)
		rockets = live
	age_puffs(now)


## Despawn any cosmetic rocket within `radius` of a real detonation point. The client rocket flies a
## pure ballistic arc (no structure march), so a rocket the server detonated against a wall would keep
## flying visually through it; when the authoritative DETONATION lands we cull the matching cosmetic
## rocket so the real blast (spawn_explosion) is the only artifact at the impact. View-only.
func cull_rockets_near(pos: Vector3, radius: float) -> void:
	if rockets.is_empty():
		return
	var live: Array = []
	for r: Dictionary in rockets:
		var node: Node3D = r["node"]
		if node.position.distance_to(pos) <= radius:
			node.queue_free()
		else:
			live.append(r)
	rockets = live


func make_rocket() -> Node3D:
	# Forward = local -Z (Basis.looking_at convention), so the warhead sits at -Z.
	var root := Node3D.new()
	root.name = "Rocket"
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.15, 0.15, 0.17); dark.metallic = 0.3; dark.roughness = 0.6
	var body := MeshInstance3D.new()
	var bmesh := BoxMesh.new(); bmesh.size = Vector3(0.16, 0.16, 0.6)
	body.mesh = bmesh; body.material_override = dark
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(body)
	var nose := MeshInstance3D.new()
	var nmesh := BoxMesh.new(); nmesh.size = Vector3(0.2, 0.2, 0.2)
	nose.mesh = nmesh; nose.position = Vector3(0, 0, -0.36)
	var nmat := StandardMaterial3D.new()
	nmat.albedo_color = Color(0.7, 0.5, 0.18); nmat.emission_enabled = true
	nmat.emission = Color(0.6, 0.35, 0.12); nmat.emission_energy_multiplier = 0.6
	nose.material_override = nmat; nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(nose)
	for ang in [0.0, PI * 0.5]:   # tail fins
		var fin := MeshInstance3D.new()
		var fmesh := BoxMesh.new(); fmesh.size = Vector3(0.36, 0.02, 0.16)
		fin.mesh = fmesh; fin.position = Vector3(0, 0, 0.28); fin.rotation = Vector3(0, 0, ang)
		fin.material_override = dark; fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(fin)
	return root


# =============================================================================
#  Thrown grenade cosmetics (M7) — local thrower feedback for frag/smoke.
# =============================================================================

## Spawn a cosmetic thrown grenade arcing from `origin` with initial `vel` (use Grenade.launch_velocity
## from the look dir, matching the server). `kind` is Grenade.FRAG / Grenade.SMOKE — only the colour
## differs. It flies the shared ballistic arc and vanishes on ground contact or at the fuse; the
## server's DETONATION / SMOKE_DEPLOYED then plays the blast / cloud at the landing point.
func throw_grenade(origin: Vector3, vel: Vector3, kind: int, now: float, friendly: bool = false) -> void:
	if not origin.is_finite() or not vel.is_finite():
		return
	var node := make_grenade(kind)
	node.position = origin
	add_child(node)
	# `friendly` (own or same-team throw) is excluded from the HUD danger warning — with FF off a
	# friendly frag can't hurt you, so warning on it is just noise (C3b).
	_pool_push(thrown, {"node": node, "vel": vel, "die": now + GRENADE_FUSE, "kind": kind, "next_trail": now, "friendly": friendly}, MAX_THROWN)


func age_thrown(now: float, delta: float) -> void:
	if thrown.is_empty():
		return
	var live: Array = []
	for g: Dictionary in thrown:
		var node: Node3D = g["node"]
		var s := Grenade.integrate(node.position, g["vel"], delta)
		var npos: Vector3 = s["pos"]
		g["vel"] = s["vel"]
		# a smoke canister leaks a faint trail so the throw reads in the air
		if int(g["kind"]) == Grenade.SMOKE and now >= float(g["next_trail"]):
			spawn_puff(node.position, 0.3, 0.45, now, Color(0.78, 0.80, 0.80, 0.4))
			g["next_trail"] = now + GRENADE_TRAIL_DT
		if now >= float(g["die"]) or npos.y <= 0.0:
			node.queue_free()   # detonation/smoke event plays the end effect at the landing point
			continue
		node.position = npos
		node.rotate_x(delta * 9.0)   # tumble in flight
		live.append(g)
	thrown = live


## World positions of the live cosmetic grenades (local throws + remote GRENADE_FX). The HUD reads
## this to warn when one is about to go off near the player. View-only — no gameplay authority.
## Enemy-thrown live grenades only (friendly ones are noise with FF off). Feeds the HUD danger warning.
func live_grenade_positions() -> Array:
	var out: Array = []
	for g: Dictionary in thrown:
		if bool(g.get("friendly", false)):
			continue
		out.append((g["node"] as Node3D).position)
	return out


func make_grenade(kind: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Grenade"
	var body := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = 0.11; sm.height = 0.30; sm.radial_segments = 8; sm.rings = 5
	body.mesh = sm
	var mat := StandardMaterial3D.new()
	# frag = dark olive, smoke = grey-green canister
	mat.albedo_color = Color(0.20, 0.24, 0.12) if kind == Grenade.FRAG else Color(0.30, 0.40, 0.34)
	mat.metallic = 0.2; mat.roughness = 0.7
	body.material_override = mat
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(body)
	return root




func spawn_puff(pos: Vector3, size: float, ttl: float, now: float, color := Color(0.55, 0.55, 0.55, 0.65)) -> void:
	var node := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = size * 0.5; sm.height = size; sm.radial_segments = 6; sm.rings = 3
	node.mesh = sm
	node.position = pos
	var mat := fx_material(color, true)
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_pool_push(puffs, {"node": node, "mat": mat, "die": now + ttl, "ttl": ttl}, MAX_PUFFS)


func age_puffs(now: float) -> void:
	if puffs.is_empty():
		return
	var live: Array = []
	for p: Dictionary in puffs:
		var remaining: float = float(p["die"]) - now
		if remaining <= 0.0:
			(p["node"] as Node3D).queue_free()
			continue
		var frac := remaining / float(p["ttl"])
		var mat: StandardMaterial3D = p["mat"]
		var c := mat.albedo_color; c.a = clampf(frac * 0.65, 0.0, 0.65); mat.albedo_color = c
		var grow := 1.0 + (1.0 - frac) * 1.3
		(p["node"] as Node3D).scale = Vector3(grow, grow, grow)
		live.append(p)
	puffs = live


# =============================================================================
#  Smoke-grenade clouds (M7) — driven by SMOKE_DEPLOYED (cosmetic, view-only).
# =============================================================================

## Pop a smoke cloud filling a `radius` zone at `pos`, living `duration` seconds. Builds a cluster of

const BLAST_TTL := 0.45        # frag fireball lifetime (s)
const FLASH_BLAST_TTL := 0.28  # flashbang white pop lifetime (s)
const DEBRIS_TTL := 0.7
const DEBRIS_GRAVITY := 18.0

## Spawn a cosmetic explosion at pos. kind: Protocol.DET_EXPLOSION (orange fireball + smoke + debris)
## or Protocol.DET_FLASH (bright white pop). Called from client_main on a DETONATION packet.
func spawn_explosion(pos: Vector3, kind: int, now: float) -> void:
	if not pos.is_finite():
		return
	if kind == 1:   # Protocol.DET_FLASH
		spawn_blast(pos + Vector3(0, 0.6, 0), Color(1.0, 1.0, 1.0), 1.2, 6.0, FLASH_BLAST_TTL, now)
		return
	# frag / impact: a fireball core + an expanding smoke puff + scattered debris
	spawn_blast(pos + Vector3(0, 0.6, 0), Color(1.0, 0.62, 0.18), 0.8, 4.2, BLAST_TTL, now)
	spawn_puff(pos + Vector3(0, 0.7, 0), 2.8, 0.75, now)
	spawn_debris(pos + Vector3(0, 0.3, 0), now)


const IMPACT_WALL_COLOR := Color(0.62, 0.60, 0.56, 0.7)    # grey wall dust
const IMPACT_DIRT_COLOR := Color(0.45, 0.36, 0.24, 0.75)   # brown dirt
const IMPACT_FLESH_COLOR := Color(0.55, 0.06, 0.06, 0.8)   # red blood mist

## Cosmetic bullet impact: a small kind-coloured puff + a few specks kicked off the surface.
## kind: Protocol.IMPACT_WALL (0) = grey wall dust, IMPACT_DIRT (1) = brown dirt,
## IMPACT_FLESH (2) = a smaller red blood mist with just a couple of droplets.
func spawn_impact(pos: Vector3, kind: int, now: float) -> void:
	if not pos.is_finite():
		return
	var col: Color
	var size: float
	var chips: int
	match kind:
		1:  # IMPACT_DIRT
			col = IMPACT_DIRT_COLOR; size = 0.6; chips = 4
		2:  # IMPACT_FLESH — a small blood mist, a couple of light droplets (no hard chips)
			col = IMPACT_FLESH_COLOR; size = 0.45; chips = 2
		_:  # IMPACT_WALL
			col = IMPACT_WALL_COLOR; size = 0.6; chips = 4
	spawn_puff(pos, size, 0.4, now, col)
	spawn_impact_chips(pos, now, col, chips)
	r.impact.emit(pos, kind)   # client_main routes this to a spatial thud (wall/dirt; flesh stays silent)

## A few small specks flung off an impact point (smaller/fewer/slower than explosion debris). Reuses
## the debris pool so age_debris integrates + settles them.
func spawn_impact_chips(pos: Vector3, now: float, color: Color, count := 4) -> void:
	if count <= 0:
		return
	var mat := fx_material(Color(color.r, color.g, color.b, 1.0))
	for i in range(count):
		var node := MeshInstance3D.new()
		var bmesh := BoxMesh.new(); bmesh.size = Vector3(0.06, 0.06, 0.06)
		node.mesh = bmesh; node.position = pos; node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		var ang := TAU * float(i) / float(count)
		var vel := Vector3(cos(ang) * 2.2, 2.6 + float(i % 2) * 1.0, sin(ang) * 2.2)
		_pool_push(debris, {"node": node, "vel": vel, "die": now + DEBRIS_TTL * 0.5}, MAX_DEBRIS)


## An emissive sphere that expands start_size -> end_size and fades over ttl. Unshaded so it reads as
## a self-lit flash regardless of scene lighting.
func spawn_blast(pos: Vector3, color: Color, start_size: float, end_size: float, ttl: float, now: float) -> void:
	var node := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = 0.5; sm.height = 1.0; sm.radial_segments = 8; sm.rings = 4
	node.mesh = sm
	node.position = pos
	var mat := fx_material(color, true, true, color, 2.5)
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_pool_push(blasts, {"node": node, "mat": mat, "born": now, "die": now + ttl, "ttl": ttl,
		"s0": start_size, "s1": end_size, "color": color}, MAX_BLASTS)


func age_blasts(now: float) -> void:
	if blasts.is_empty():
		return
	var live: Array = []
	for b: Dictionary in blasts:
		var remaining: float = float(b["die"]) - now
		if remaining <= 0.0:
			(b["node"] as Node3D).queue_free()
			continue
		var t := 1.0 - remaining / float(b["ttl"])   # 0 -> 1 over life
		var size: float = lerpf(float(b["s0"]), float(b["s1"]), sqrt(t))   # fast initial expansion
		(b["node"] as Node3D).scale = Vector3(size, size, size)
		var mat: StandardMaterial3D = b["mat"]
		var c: Color = b["color"]; c.a = clampf(1.0 - t, 0.0, 1.0); mat.albedo_color = c
		mat.emission_energy_multiplier = 2.5 * (1.0 - t)
		live.append(b)
	blasts = live


func spawn_debris(pos: Vector3, now: float) -> void:
	var dark := fx_material(Color(0.18, 0.16, 0.14))
	for i in range(7):
		var node := MeshInstance3D.new()
		var bmesh := BoxMesh.new(); bmesh.size = Vector3(0.12, 0.12, 0.12)
		node.mesh = bmesh; node.position = pos; node.material_override = dark
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		# Fan outward + up; vary by index so each piece flies differently (no per-frame RNG).
		var ang := TAU * float(i) / 7.0
		var vel := Vector3(cos(ang) * 5.0, 6.0 + float(i % 3) * 1.5, sin(ang) * 5.0)
		_pool_push(debris, {"node": node, "vel": vel, "die": now + DEBRIS_TTL}, MAX_DEBRIS)


func age_debris(now: float, delta: float) -> void:
	if debris.is_empty():
		return
	var dt := clampf(delta, 0.0, 0.1)   # ignore absurd startup/stall deltas so debris can't fling to INF
	var live: Array = []
	for d: Dictionary in debris:
		if now >= float(d["die"]):
			(d["node"] as Node3D).queue_free()
			continue
		var node: Node3D = d["node"]
		var vel: Vector3 = d["vel"]
		vel.y -= DEBRIS_GRAVITY * dt
		var npos := node.position + vel * dt
		if npos.y < 0.0:
			npos.y = 0.0; vel = Vector3.ZERO   # settle on the ground
		node.position = npos
		d["vel"] = vel
		live.append(d)
	debris = live

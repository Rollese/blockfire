class_name ServerFire
extends RefCounted
## Server bullet pipeline, extracted from server_main (batch 5 D1): trigger resolution
## (infantry hit-scan gate + mounted-gun lag-comp path), projectile spawning, and the
## per-tick stepped-projectile integration (broadphase, suppression, penetration, damage).
## Owns the live projectile pool; all other state stays on the server (back-ref `s`).

var srv   # ServerMain back-ref (untyped: server_main.gd declares no class_name)

const MAX_LIVE_PROJECTILES := 1024

var projectiles: Array = []  # [{owner, team, weapon_id, …scalars…, pos, vel, spawn_tick, dist, ttl}]


func _init(server) -> void:
	srv = server


func resolve_vehicle_fires() -> void:
	for vid in srv._sim.world.vehicles:
		var v: Vehicle = srv._sim.world.vehicles[vid]
		if not v.alive or v.mounted.is_empty(): continue
		var gunner := 0
		for seat in v.seats.size():
			if int(v.seat_roles[seat]) == Vehicle.ROLE_GUNNER and int(v.seats[seat]) != 0:
				gunner = int(v.seats[seat]); break
		if gunner == 0 or not srv._clients.has(gunner): continue
		var inp = srv._clients[gunner]["last_input"]
		if inp == null or (int(inp["buttons"]) & InputCommand.BTN_FIRE) == 0: continue
		var interval := float(v.mounted["fire_interval"])
		if (float(srv._sim.tick) - float(v.last_mounted_fire_tick)) * SimLoop.DT < interval: continue
		v.last_mounted_fire_tick = srv._sim.tick
		var gp: Pawn = srv._sim.world.get_pawn(gunner)
		if gp == null: continue
		var origin := v.turret_muzzle()
		var dir := Combat._forward(v.turret_yaw, gp.pitch)
		# Cosmetic: tracer + muzzle flash + gunfire sound at the turret muzzle (the mounted gun was
		# previously silent + flashless to everyone). Reuses the infantry SHOT_FX path.
		srv._broadcast_shot_fx(gunner, origin, dir)
		var max_range := float(v.mounted["range_m"])
		var view_tick: int = int(inp["view_server_tick"])
		if srv._lag.clamped(view_tick):
			srv._stats.rewind_clamped += 1   # gunner's view older than the rewind horizon (telemetry)
		var frame: Dictionary = srv._lag.rewind(view_tick)
		var candidates: Array = srv._grid.query(origin, max_range + srv.FIRE_RANGE_MARGIN, srv._positions)
		var best_t := max_range + 1.0
		var best_victim := 0
		var best_head := false
		for tid in candidates:
			if tid == gunner: continue
			if not frame.has(tid): continue
			var stt = frame[tid]
			if not stt["alive"] or stt["team"] == v.team: continue
			var vcenter: Vector3 = stt["pos"] + Vector3(0.0, Stance.body_height(stt["stance"]) * 0.5, 0.0)
			var to_target: Vector3 = vcenter - origin
			if to_target.length() > max_range: continue
			if to_target.length() > srv.FIRE_CONE_SKIP_RANGE and to_target.normalized().dot(dir) < srv.FIRE_CONE_DOT: continue
			var hit := Hitbox.raycast_pawn(origin, dir, stt["pos"], stt["stance"], max_range)
			if hit["hit"] and hit["t"] < best_t:
				best_t = hit["t"]; best_victim = tid; best_head = hit["headshot"]
		if best_victim == 0: continue
		# Structure occlusion: the infantry projectile path marches the store for cover, this hitscan
		# path never did — mounted guns shot through every wall on the map. A piece strictly nearer
		# than the victim blocks the round (chips the wall, no penetration for mounted guns).
		if srv._store != null and srv._store.count() > 0:
			var blocked: Dictionary = srv._store.march(origin, dir, best_t)
			if bool(blocked["hit"]) and float(blocked["dist"]) < best_t:
				var hit_pt: Vector3 = origin + dir * float(blocked["dist"])
				srv._stats.shots += 1
				srv._stats.shots_blocked += 1
				srv._damage_structure(int(blocked["id"]), PieceCatalog.SRC_BULLET, hit_pt, srv.BULLET_CARVE_RADIUS)
				srv._broadcast_impact_fx(hit_pt, Protocol.IMPACT_WALL)   # cosmetic: round stopped by cover
				continue
		var victim: Pawn = srv._sim.world.get_pawn(best_victim)
		if victim == null or not victim.alive: continue
		srv._stats.shots += 1; srv._stats.hits += 1
		srv._broadcast_impact_fx(origin + dir * best_t, Protocol.IMPACT_FLESH)   # cosmetic blood mist at the hit
		srv._apply_pawn_damage(best_victim, victim, int(v.mounted["damage"]), best_head, Revive.Source.BULLET, gunner, 0)
		# Hitmarker to a human gunner (lethal = killed or downed), mirroring the infantry fire path.
		var gsc: Dictionary = srv._clients.get(gunner, {})
		if not gsc.is_empty() and not gsc.get("auto_deploy", true):
			var glethal: bool = (not victim.alive) or victim.is_downed
			srv._net.send_to(gsc["peer"], NetHost.CHANNEL_CONTROL, Protocol.encode_hitmarker(best_head, glethal), 0)

func resolve_fires() -> void:
	for id in srv._clients:
		var c = srv._clients[id]
		var inp = c["last_input"]
		if inp == null: continue
		var shooter: Pawn = srv._sim.world.get_pawn(id)
		if shooter == null or not shooter.alive or shooter.is_downed or shooter.climbing: continue   # downed/climbing = can't fire (also drops ADS accuracy, read below)
		if c["weapon"] == Weapon.RPG:
			c["shot_index"] = 0
			# RPG fires via GADGET_ACTION(GA_RPG_FIRE), not the hit-scan path. RELOAD refills the rocket pool.
			var rpg_max := int(srv._gadgets.def_of_kind(Gadget.KIND_RPG)["ammo"])
			if (inp["buttons"] & InputCommand.BTN_RELOAD) and not c["reloading"] and int(c["rockets"]) < rpg_max:
				c["reloading"] = true
				c["reload_done_tick"] = srv._sim.tick + int(round(srv.RPG_RELOAD_SECS * srv.TICK_RATE))
				srv._broadcast_reload_fx(id, int(c["reload_done_tick"]) - srv._sim.tick)
			continue
		var firing: bool = (inp["buttons"] & InputCommand.BTN_FIRE) != 0
		if not firing:
			c["shot_index"] = 0
			if (inp["buttons"] & InputCommand.BTN_RELOAD) and not c["reloading"] and c["ammo"] < Weapon.get_def(c["weapon"])["mag_size"]:
				c["reloading"] = true
				c["reload_done_tick"] = srv._sim.tick + int(round(Weapon.get_def(c["weapon"])["reload_secs"] * srv.TICK_RATE))
				srv._broadcast_reload_fx(id, int(c["reload_done_tick"]) - srv._sim.tick)
			continue
		var now := float(srv._sim.tick) * SimLoop.DT
		var ready: bool = now - c["last_fire_time"] >= Weapon.fire_interval(c["weapon"])
		var sprinting: bool = (inp["buttons"] & InputCommand.BTN_SPRINT) and shooter.stance == Stance.STAND
		var drop_shoot: bool = Combat.drop_shoot_blocked(shooter.stance, srv._sim.tick, shooter.last_stance_change_tick)
		var mode: int = int(c.get("fire_mode", Weapon.default_mode(c["weapon"])))
		var burst: int = int(Weapon.get_def(c["weapon"]).get("burst_count", Weapon.DEFAULT_BURST))
		var mode_ok: bool = Weapon.fire_allowed(mode, c["shot_index"], burst)
		var equipping: bool = srv._sim.tick < int(c.get("swap_locked_until", 0))
		if c["reloading"] or c["ammo"] <= 0 or not ready or sprinting or drop_shoot or not mode_ok or equipping:
			if drop_shoot:
				srv._stats.drop_shoot_blocked += 1
			continue
		c["last_fire_time"] = now
		c["ammo"] -= 1
		var shot_index: int = c["shot_index"]
		c["shot_index"] = shot_index + 1
		srv._stats.shots += 1
		fire_shot(id, shooter, inp, shot_index)


func fire_shot(shooter_id: int, shooter: Pawn, inp: Dictionary, shot_index: int) -> void:
	var lean_sign := 0
	if shooter.lean == Stance.LEAN_LEFT: lean_sign = -1
	elif shooter.lean == Stance.LEAN_RIGHT: lean_sign = 1
	var moving: bool = absf(inp["move_x"]) + absf(inp["move_y"]) > 0.01
	var wid: int = srv._clients[shooter_id]["weapon"]
	var wdef: Dictionary = srv._clients[shooter_id]["weapon_def"]
	var prone: bool = shooter.stance == Stance.PRONE
	var supp_deg := Suppress.spread_penalty_deg(shooter.suppression)   # M5.5-P2: incoming fire widens our spread
	# Aim-down-sights tightens spread. Authoritative: honour the bit only when not sprinting (you can't
	# physically ADS mid-sprint), so a client can't claim ADS accuracy while sprint-running.
	var sprinting: bool = (int(inp["buttons"]) & InputCommand.BTN_SPRINT) != 0 and shooter.stance == Stance.STAND
	var aiming: bool = (int(inp["buttons"]) & InputCommand.BTN_AIM) != 0 and not sprinting
	var ray := Combat.reconstruct_ray(wid, shooter.eye_position(),
		inp["yaw"], inp["pitch"], lean_sign, shooter_id, srv._sim.tick, shot_index, moving, prone, wdef, supp_deg, aiming)

	# Cosmetic: tell human clients (renderers) about this shot so remote pawns show a tracer.
	srv._broadcast_shot_fx(shooter_id, ray["origin"], ray["dir"])

	# M5.5-P1: bullets are stepped server-side projectiles. Spawn at the COMMAND tick, then step in
	# PRESENT time (no per-shot lag-comp rewind for bullets — travel time masks latency). The hit is
	# resolved later in step_projectiles (broadphase + penetration + srv._apply_pawn_damage + hitmarker).
	var wmv: float = float(wdef["muzzle_velocity"])
	# Lag comp: the shooter fired at the world they were RENDERING (~100 ms in the past). Rewind
	# targets by that latency for the bullet's whole flight so "aim where you see them" connects on
	# movers. view_server_tick<=0 (bots) -> lag 0 -> present-time resolve (unchanged). Bounded by the
	# lag-comp horizon so a stale/hostile view tick can't rewind arbitrarily far.
	var view_tick: int = int(inp.get("view_server_tick", 0))
	var lag: int = clampi(srv._sim.tick - view_tick, 0, LagComp.MAX_REWIND) if view_tick > 0 else 0
	if projectiles.size() < MAX_LIVE_PROJECTILES:
		# Store the scalars step_projectiles uses, not the wdef ref — the projectile is conceptually
		# shared with the future M7 client tracer, which has no server def dict (self-contained).
		projectiles.append({
			"owner": shooter_id, "team": shooter.team, "weapon_id": wid,
			"gravity_scale": float(wdef["gravity_scale"]), "range_m": float(wdef["range_m"]),
			"damage_body": int(wdef["damage_body"]), "headshot_mult": float(wdef["headshot_mult"]),
			"pos": ray["origin"], "vel": Projectile.initial_velocity(ray["dir"], wmv),
			"spawn_tick": srv._sim.tick, "dist": 0.0, "ttl": Weapon.projectile_ttl_ticks(wid),
			"lag_ticks": lag,
		})
		srv._stats.proj_fired += 1
	else:
		srv._stats.proj_dropped += 1

# Test seam: spawn a projectile for a known owner/weapon/dir without going through input/loadout.
# Used by tests/projectile_gate_test.gd; never called in production.
func spawn_projectile_for_test(owner: int, wid: int, pos: Vector3, dir: Vector3, lag_ticks: int = 0) -> void:
	var p: Pawn = srv._sim.world.get_pawn(owner)
	var wdef: Dictionary = Weapon.get_def(wid)
	projectiles.append({"owner": owner, "team": (p.team if p else 0), "weapon_id": wid,
		"gravity_scale": float(wdef["gravity_scale"]), "range_m": float(wdef["range_m"]),
		"damage_body": int(wdef["damage_body"]), "headshot_mult": float(wdef["headshot_mult"]),
		"pos": pos, "vel": Projectile.initial_velocity(dir, float(wdef["muzzle_velocity"])),
		"spawn_tick": srv._sim.tick, "dist": 0.0, "ttl": Weapon.projectile_ttl_ticks(wid),
		"lag_ticks": lag_ticks})

# Integrate each live bullet one tick, raycast its per-tick segment against enemy pawns (interest-grid
# broadphase) + the structure store (penetration), and on a confirmed pawn hit apply damage. Models on
# _step_rockets; per-shot `return`s from the old fire_shot become `continue` (drop one projectile, keep
# iterating the pool). PRESENT-time resolve — no lag-comp rewind for bullets.
## Shortest distance from point `p` to segment a→b (for near-miss suppression).
func point_seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var denom := ab.length_squared()
	var t := clampf((p - a).dot(ab) / denom, 0.0, 1.0) if denom > 0.0 else 0.0
	return p.distance_to(a + ab * t)

func step_projectiles() -> void:
	srv._impact_fx_this_tick = 0   # reset the per-tick cosmetic-impact cap
	if projectiles.is_empty():
		return
	var still: Array = []
	for pr in projectiles:
		var wid: int = int(pr["weapon_id"])
		var max_range: float = float(pr["range_m"])
		var gscale: float = float(pr["gravity_scale"])
		var old_pos: Vector3 = pr["pos"]
		var s := Projectile.integrate(old_pos, pr["vel"], gscale, SimLoop.DT)
		var nxt: Vector3 = s["pos"]
		var seg: Vector3 = nxt - old_pos
		var seg_len := seg.length()
		var seg_dir: Vector3 = seg / seg_len if seg_len > 0.0001 else Vector3.FORWARD

		# Broad-phase: enemy pawns whose hitbox the segment could cross this tick (current positions
		# + lag-comp margin). Bound the ray test to the segment length.
		var candidates: Array = srv._grid.query(old_pos, seg_len + srv.FIRE_RANGE_MARGIN, srv._positions)
		# Lag comp: for a human shooter, resolve hits against where each target WAS at the shooter's
		# view tick (present - lag_ticks), not its present position — see fire_shot. lag 0 (bots) reads
		# present. The frame is fetched once per projectile per tick; missing ids fall back to present.
		var lag: int = int(pr.get("lag_ticks", 0))
		var lag_frame: Dictionary = srv._lag.rewind(srv._sim.tick - lag) if lag > 0 else {}
		var best_t := seg_len + 1.0
		var best_victim := 0
		var best_head := false
		for tid in candidates:
			if tid == int(pr["owner"]): continue
			var tgt: Pawn = srv._sim.world.get_pawn(tid)
			if tgt == null or not tgt.alive: continue
			if tgt.team == int(pr["team"]): continue
			# Geometry (position + stance capsule) rewound to the shooter's view; liveness/team/downed
			# and suppression accrual stay on the PRESENT pawn.
			var tpos: Vector3 = tgt.pos
			var tstance: int = tgt.stance
			if lag_frame.has(tid):
				tpos = lag_frame[tid]["pos"]
				tstance = int(lag_frame[tid]["stance"])
			# Downed pawns are immune (BattleBit-style no finishing): the bullet does no damage and
			# never blocks (passes through to whatever's behind), but show a cosmetic blood impact if
			# the round actually hits the body — feedback that you're firing on someone already down.
			if tgt.is_downed:
				var dhit := Hitbox.raycast_pawn(old_pos, seg_dir, tpos, tstance, seg_len)
				if dhit["hit"]:
					srv._broadcast_impact_fx(old_pos + seg_dir * float(dhit["t"]), Protocol.IMPACT_FLESH)
				continue
			# M5.5-P2 suppression: a live enemy bullet whose segment passes within SUPPRESS_RADIUS of
			# the pawn raises its suppression (closer = more), whether or not it lands. Measured against
			# the segment (point-to-segment distance) so a fast bullet still suppresses across one tick.
			var miss := point_seg_dist(tpos, old_pos, nxt)
			if miss < Suppress.SUPPRESS_RADIUS:
				tgt.suppression = Suppress.accrue(tgt.suppression, miss)
				srv._stats.suppress_events += 1
			var hit := Hitbox.raycast_pawn(old_pos, seg_dir, tpos, tstance, seg_len)
			if hit["hit"] and hit["t"] < best_t:
				best_t = hit["t"]; best_victim = tid; best_head = hit["headshot"]

		# Enemy hit damage (incl. headshot/range over total distance flown). Penetration scales it.
		# Reconstruct the minimal def from the projectile's captured scalars so attachment-modified
		# falloff/headshot are preserved without holding a wdef ref.
		var enemy_dmg := 0
		if best_victim != 0:
			# beyond weapon range -> 0 dmg -> bullet consumed silently (range falloff)
			enemy_dmg = Combat.damage_for(wid, best_head, float(pr["dist"]) + best_t,
				{"range_m": float(pr["range_m"]), "damage_body": int(pr["damage_body"]),
				"headshot_mult": float(pr["headshot_mult"])})
		var body_dmg := int(pr["damage_body"])

		# Cover / penetration: a structure strictly nearer than the enemy along THIS segment.
		if srv._store.count() > 0 and seg_len > 0.0001:
			var march_max: float = best_t if best_victim != 0 else seg_len
			var blocked: Dictionary = srv._store.march(old_pos, seg_dir, march_max)
			if blocked["hit"] and float(blocked["dist"]) < best_t:
				var block_id := int(blocked["id"])
				var rec: Dictionary = srv._store.get_record(block_id)
				if rec.is_empty():
					continue   # piece gone (defensive)
				var hit_pt: Vector3 = old_pos + seg_dir * float(blocked["dist"])
				var mat: int = srv._catalog.material_of(int(rec["type"]))
				srv._stats.shots_blocked += 1
				if not PieceCatalog.is_penetrable(mat):
					srv._damage_structure(block_id, PieceCatalog.SRC_BULLET, hit_pt, srv.BULLET_CARVE_RADIUS)
					srv._broadcast_impact_fx(hit_pt, Protocol.IMPACT_WALL)   # cosmetic: bullet chips the wall
					continue   # stopped by cover — consume the bullet
				# Penetrable: bullet exits at *transmit. Piece is carved geometrically (M11).
				var split := Combat.apply_penetration(body_dmg, enemy_dmg,
					PieceCatalog.absorption_of(mat), PieceCatalog.transmit_of(mat))
				srv._damage_structure(block_id, PieceCatalog.SRC_BULLET, hit_pt, srv.BULLET_CARVE_RADIUS)
				srv._broadcast_impact_fx(hit_pt, Protocol.IMPACT_WALL)   # cosmetic: dust where it punches through
				if srv._store.get_record(block_id).is_empty():
					continue   # 1-pen: piece destroyed by this bullet consumes it
				if best_victim == 0:
					continue   # nothing beyond to hit; bullet passed through but found no pawn
				srv._stats.pen += 1
				enemy_dmg = int(split["exit_damage"])

		if best_victim != 0 and enemy_dmg > 0:
			var victim: Pawn = srv._sim.world.get_pawn(best_victim)
			if victim != null and victim.alive:
				srv._stats.hits += 1
				srv._stats.proj_hits += 1
				srv._broadcast_impact_fx(old_pos + seg_dir * best_t, Protocol.IMPACT_FLESH)   # cosmetic blood mist at the hit
				srv._apply_pawn_damage(best_victim, victim, enemy_dmg, best_head, Revive.Source.BULLET,
					int(pr["owner"]), wid)
				# Hitmarker to the (human, manually-deployed) shooter — lethal = killed or downed.
				var sc: Dictionary = srv._clients.get(int(pr["owner"]), {})
				if not sc.is_empty() and not sc.get("auto_deploy", true):
					var lethal: bool = (not victim.alive) or victim.is_downed
					srv._net.send_to(sc["peer"], NetHost.CHANNEL_CONTROL,
						Protocol.encode_hitmarker(best_head, lethal), 0)
			continue   # bullet consumed on a pawn hit

		# Miss this tick: advance state and decide whether the bullet lives on.
		pr["pos"] = nxt
		pr["vel"] = s["vel"]
		pr["dist"] = float(pr["dist"]) + seg_len
		srv._stats.dbg_last_min_y = minf(srv._stats.dbg_last_min_y, nxt.y)
		if nxt.y <= 0.0:
			# Cosmetic dirt puff at the ground-impact point (lerp the segment to y=0 for accuracy).
			var gt: float = old_pos.y / (old_pos.y - nxt.y) if old_pos.y > nxt.y else 1.0
			srv._broadcast_impact_fx(old_pos + (nxt - old_pos) * gt, Protocol.IMPACT_DIRT)
			continue   # hit the ground
		if Projectile.expired(srv._sim.tick - int(pr["spawn_tick"]), int(pr["ttl"]),
				float(pr["dist"]), max_range):
			continue
		still.append(pr)
	projectiles = still
	srv._stats.proj_live_max = maxi(srv._stats.proj_live_max, projectiles.size())

class_name BotExercisers
extends RefCounted
## Gate-exerciser behaviours physically moved out of bot_driver (batch 5 D4, owner-requested):
## climb/shovel drills, FOB-leader drill, grenade/smoke/throwable/melee/sledge, weapon handling
## (fire-mode + swap), RPG (incl. vs buildings), C4/mine, medic give, and their helpers. Role
## COHORTS live in bots/roles.gd; per-bot state stays in the bot Dictionary; fleet plumbing
## (sockets, _send, nav) stays on the driver (back-ref `d`).

const Protocol := preload("res://shared/net/protocol.gd")
const Roles := preload("res://bots/roles.gd")

var d   # BotDriver back-ref (Node; owns this module)


func _init(driver) -> void:
	d = driver


func update_drill_phase(bot: Dictionary, next_phase: int) -> void:
	var cur_phase: int = int(bot.get("drill_phase", AiDrill.DRILL_CLIMB))
	var ticks: int = int(bot.get("drill_phase_ticks", 0))
	if next_phase != cur_phase:
		# Phase transition from drill_step logic.
		bot["drill_phase"] = next_phase
		bot["drill_phase_ticks"] = 0
	else:
		ticks += 1
		if ticks >= AiDrill.DRILL_PHASE_TIMEOUT:
			# Stuck: force the other phase and reset.
			bot["drill_phase"] = AiDrill.DRILL_VAULT if cur_phase == AiDrill.DRILL_CLIMB else AiDrill.DRILL_CLIMB
			bot["drill_phase_ticks"] = 0
		else:
			bot["drill_phase_ticks"] = ticks

## (is_closest_reviver / nearest_downed_teammate removed 2026-07-04: dead duplicates of the LIVE
## revive selection in AiSupport.pick_revive_target since M7.5-P3 — they had already drifted, e.g.
## the medic range asymmetry was absent here.)

func maybe_build(bot: Dictionary, me: EntityState) -> void:
	if int(bot["builds_made"]) >= d.MAX_BOT_BUILDS:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_build_tick"]) < d.BUILD_COOLDOWN_TICKS:
		return
	# Drop cover to the bot's SIDE (perpendicular to its facing), one step away. The caller only
	# invokes this while stationary. A full-height WALL is used so it blocks standing eye-height
	# shots (a half-height sandbag sits below the ~1.6 m sight line and never blocks combat).
	# Placing it to the side rather than down the firing line means the bot keeps engaging
	# forward (so attrition still converges the match) while the wall blocks flanking crossfire.
	var dir := Vector2(cos(me.yaw), -sin(me.yaw))   # right-hand perpendicular to facing
	var target: Vector3 = me.pos + Vector3(dir.x, 0.0, dir.y) * d.BUILD_DIST
	var cell := BuildGrid.cell_of(Vector3(target.x, 0.0, target.z))
	var yaw_step := int(round(me.yaw / (TAU / float(BuildGrid.YAW_STEPS)))) % BuildGrid.YAW_STEPS
	if yaw_step < 0: yaw_step += BuildGrid.YAW_STEPS
	var bytes := Protocol.encode_build_request(1, cell, yaw_step)   # type 1 = wall (full height)
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, bytes, 0)
	bot["last_build_tick"] = st
	bot["builds_made"] = int(bot["builds_made"]) + 1

## M12-P2 shovel-driller (BotRoles.SHOVEL): place build sites + hold BTN_SHOVEL to build them, and
## shovel finished structures the server then auto-repairs (friendly+holed) or dismantles (enemy).
## Self-contained: computes move + buttons and _sends, so it never runs combat or the side-wall build.
## A LARGE-cooperation sub-subset (BotRoles.large_coop) converges on ONE shared per-team heavy_barricade
## cell so >=2 of them build it together (built_large); a lone one there trips bsolo while it waits.
func drive_shovel_driller(bot: Dictionary, me: EntityState) -> void:
	var structs: Dictionary = bot["structs"]
	var is_large: bool = Roles.large_coop(int(bot["index"]))

	# 1. Pick a work target cell (Vector3i). Build sites are PRIMARY (so the structure-dense map's
	#    finished pieces never starve the build path); shovelling a nearby finished structure (repair/
	#    dismantle) is the fallback once a driller has spent its build cap.
	var target_cell := Vector3i.ZERO
	var have_target := false

	if is_large and d._map != null and not d._map.base_for(int(me.team)).is_empty():
		# Large-cooperation: every large driller on the team locks the SAME shared cell so >=2 converge.
		# M12-P3: the squad LEADERS place a FOB site at this cell (see drive_fob_leader); the large
		# drillers no longer place a heavy_barricade here — they just converge + shovel whatever site is
		# there, adding builders to the FOB so it clears min_builders=2 and completes (built_large fires).
		target_cell = shared_large_cell(int(me.team))
		have_target = true
	else:
		var have_base: bool = d._map != null and not d._map.base_for(int(me.team)).is_empty()
		# (P1) Commit to a sticky own build cell until the site finishes (or proves rejected/decayed).
		#      This is what stops the structure-dense map's branch-(P3) shovel from diverting a driller
		#      off its half-built wall every tick.
		if bool(bot.get("has_build", false)):
			var bc: Vector3i = bot["build_cell"]
			var rec := struct_at(structs, bc)
			if not rec.is_empty():
				if int(rec.get("under_construction", 0)) == 1:
					target_cell = bc; have_target = true        # still building -> stay on it
				else:
					bot["has_build"] = false                    # completed -> release
			elif int(bot["server_tick"]) - int(bot.get("build_set_tick", 0)) < d.BUILD_COMMIT_TICKS:
				target_cell = bc; have_target = true            # placed; site delta in flight -> hold
			else:
				# Placed but the site never appeared (cell occupied / lost race on the dense gate map):
				# shift to a fresh lane next pass and refund the cap (nothing was actually built).
				bot["has_build"] = false
				bot["build_attempt"] = int(bot.get("build_attempt", 0)) + 1
				bot["builds_made"] = maxi(0, int(bot["builds_made"]) - 1)
		# (P2) Head to a CLEAR per-driller lane cell near the team base and place a wall there once in
		#      BUILD_RANGE. Ahead-of-facing placement (old _wall_cell) collided with the dense map's
		#      prebuilt pieces and got rejected -> built_small never fired; a clear near-base lane fixes it.
		if not have_target and have_base and int(bot["builds_made"]) < d.MAX_BOT_BUILDS:
			var seed: int = int(bot["id"]) + int(bot.get("build_attempt", 0))   # id is globally unique
			var bc := Vector3i.ZERO
			var clear := false
			for k in d.SMALL_LANES:
				var cand := small_build_cell(int(me.team), seed + k)
				if struct_at(structs, cand).is_empty():
					bc = cand; clear = true; break
			if clear:
				target_cell = bc; have_target = true
				if me.pos.distance_to(BuildGrid.world_of(bc)) <= StructureStore.BUILD_RANGE - 0.5:
					if place_site(bot, me, d.WALL_TYPE, bc):
						bot["has_build"] = true
						bot["build_cell"] = bc
						bot["build_set_tick"] = int(bot["server_tick"])
		# (P3) Fallback (build done / capped / no base): seek the nearest known structure in range and
		#      shovel it — the server repairs it (friendly + holed) or dismantles it (enemy). Wide range
		#      so a driller that has finished building roams to a real structure instead of idling.
		if not have_target:
			var best_d: float = d.SHOVEL_SEEK_RANGE
			for sid in structs:
				var wp: Vector3 = BuildGrid.world_of(structs[sid]["cell"] as Vector3i)
				var d := me.pos.distance_to(wp)
				if d < best_d:
					best_d = d; target_cell = structs[sid]["cell"]; have_target = true

	if not have_target:
		# Nothing to work yet (e.g. build on cooldown, no structure in seek range) — hold + face forward.
		d._send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# 2. Steer to the target and shovel. Face the centre (atan2(dir.x, dir.z)); stop + hold BTN_SHOVEL
	#    once within range so the server accrues progress / repairs / dismantles.
	var center := BuildGrid.world_of(target_cell)
	var to := center - me.pos
	var flat := Vector2(to.x, to.z)
	var dist := flat.length()
	var move_x := 0.0
	var move_y := 0.0
	var buttons := 0
	if dist > 0.001:
		bot["yaw"] = atan2(to.x, to.z)
	if dist <= d.SHOVEL_APPROACH:
		pass   # in range: hold position
	else:
		var n := flat / dist
		move_x = n.x; move_y = n.y
	if dist <= BuildSite.SHOVEL_RANGE:
		buttons |= InputCommand.BTN_SHOVEL   # server resolves build vs repair vs dismantle
	d._send(bot, move_x, move_y, bot["yaw"], 0.0, buttons)

## Deterministic shared heavy_barricade cell for a team: 4 m in front of the team base toward the map
## centre (origin), snapped to a build cell. Every large driller on the team computes the same cell so
## they converge on one site. Reachable (near spawn) and clear of the base itself.
func shared_large_cell(team: int) -> Vector3i:
	var bpos: Vector3 = d._map.base_for(team)["pos"]
	var toward := Vector3(-bpos.x, 0.0, -bpos.z)
	if toward.length() < 0.01:
		toward = Vector3(0.0, 0.0, 1.0)
	var p := bpos + toward.normalized() * 4.0
	return BuildGrid.cell_of(Vector3(p.x, 0.0, p.z))

## A clear per-driller wall cell near the team base: d.SMALL_BUILD_DEPTH in front of the base toward the
## map centre, then offset laterally into a lane derived from `seed` (per-driller, so drillers don't
## stack), snapped to a build cell. Mirrors shared_large_cell but spreads small drillers into lanes.
## The caller scans d.SMALL_LANES consecutive seeds for the first cell with no known structure, so the
## dense gate map's prebuilt pieces (and other drillers' walls) are avoided instead of colliding.
func small_build_cell(team: int, seed: int) -> Vector3i:
	var bpos: Vector3 = d._map.base_for(team)["pos"]
	var toward := Vector3(-bpos.x, 0.0, -bpos.z)
	if toward.length() < 0.01:
		toward = Vector3(0.0, 0.0, 1.0)
	toward = toward.normalized()
	var perp := Vector3(-toward.z, 0.0, toward.x)       # lateral axis across the base->centre line
	var lane: int = (seed % d.SMALL_LANES) - d.SMALL_LANES / 2  # spread both sides of the approach line
	var p: Vector3 = bpos + toward * d.SMALL_BUILD_DEPTH + perp * (float(lane) * BuildGrid.CELL_SIZE)
	return BuildGrid.cell_of(Vector3(p.x, 0.0, p.z))

## The known structure/site record at `cell` (empty Dictionary if none).
func struct_at(structs: Dictionary, cell: Vector3i) -> Dictionary:
	for sid in structs:
		if (structs[sid]["cell"] as Vector3i) == cell:
			return structs[sid]
	return {}

## Send a BUILD_REQUEST for `type` at `cell` if the per-bot cap + cooldown allow. Returns true if sent.
## The server independently validates range/occupancy/cooldown, so a rejected request is harmless.
func place_site(bot: Dictionary, me: EntityState, type: int, cell: Vector3i) -> bool:
	if int(bot["builds_made"]) >= d.MAX_BOT_BUILDS:
		return false
	var st: int = bot["server_tick"]
	if st - int(bot["last_build_tick"]) < d.BUILD_COOLDOWN_TICKS:
		return false
	var yaw_step := int(round(me.yaw / (TAU / float(BuildGrid.YAW_STEPS)))) % BuildGrid.YAW_STEPS
	if yaw_step < 0: yaw_step += BuildGrid.YAW_STEPS
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_build_request(type, cell, yaw_step), 0)
	bot["last_build_tick"] = st
	bot["builds_made"] = int(bot["builds_made"]) + 1
	return true

## M12-P3: true if this bot is its squad's leader — the lowest id among the visible same-team +
## same-squad pawns (plus itself). The server independently re-checks leadership on PLACE_FOB, so a
## false positive (a closer-but-not-actually-lowest id off-view) just yields a harmless rejected request.
func is_squad_leader(bot: Dictionary, me: EntityState) -> bool:
	var ids: Array = [int(bot["id"])]
	var view: Dictionary = bot["view"]
	for id in view:
		var e: EntityState = view[id]
		if int(e.team) == int(me.team) and int(e.squad) == int(me.squad):
			ids.append(int(id))
	return Fob.is_squad_leader(int(bot["id"]), ids)

## M12-P3: send a PLACE_FOB for `cell` if the per-bot FOB cooldown allows. PLACE_FOB is leader-only +
## UNCAPPED server-side, so it does NOT consume the builds_made cap (unlike place_site). Returns true
## if sent. The server validates leader/occupancy/placement, so a rejected request is harmless.
func place_fob(bot: Dictionary, me: EntityState, cell: Vector3i) -> bool:
	var st: int = bot["server_tick"]
	if st - int(bot.get("last_fob_tick", -100000)) < d.BUILD_COOLDOWN_TICKS:
		return false
	var yaw_step := int(round(me.yaw / (TAU / float(BuildGrid.YAW_STEPS)))) % BuildGrid.YAW_STEPS
	if yaw_step < 0: yaw_step += BuildGrid.YAW_STEPS
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_place_fob(cell, yaw_step), 0)
	bot["last_fob_tick"] = st
	return true

## M12-P3: true if this bot should run the FOB drill — it is its squad's leader AND the per-team shared
## cell does NOT yet hold a COMPLETED structure (empty or under_construction) AND it has not been drilling
## past d.FOB_DRILL_MAX_TICKS. Tracks fob_drill_start (first active tick); resets it once the FOB completes
## so a destroyed-then-absent FOB can be rebuilt on a fresh evaluation (respawn also resets it).
func fob_drill_active(bot: Dictionary, me: EntityState) -> bool:
	if not is_squad_leader(bot, me):
		return false
	var structs: Dictionary = bot["structs"]
	var cell: Vector3i = shared_large_cell(int(me.team))
	var rec: Dictionary = struct_at(structs, cell)
	if not rec.is_empty() and int(rec.get("under_construction", 0)) == 0:
		bot["fob_drill_start"] = -1   # FOB (or a structure) is up at the cell -> stop drilling, reset
		return false
	var now: int = int(bot["server_tick"])
	var start: int = int(bot.get("fob_drill_start", -1))
	if start < 0:
		bot["fob_drill_start"] = now
		start = now
	if now - start > d.FOB_DRILL_MAX_TICKS:
		return false   # deadline exceeded -> fall through to normal AI (never babysit a failing cell)
	return true

## M12-P3 FOB leader drill: a squad leader whose squad has no completed FOB yet steers to the per-team
## shared cell, places a FOB site there (PLACE_FOB), and holds BTN_SHOVEL to build it. Mirrors the
## shovel-driller's steer+shovel step; the large shovel-drillers converge on the SAME cell and shovel
## it too, so leader + drillers exceed the FOB's min_builders=2 and it completes (fobs_built fires).
## Self-contained: computes move + buttons and _sends, overriding combat until the FOB is up (or deadline).
func drive_fob_leader(bot: Dictionary, me: EntityState) -> void:
	var structs: Dictionary = bot["structs"]
	var cell: Vector3i = shared_large_cell(int(me.team))
	var center := BuildGrid.world_of(cell)
	var to := center - me.pos
	var flat := Vector2(to.x, to.z)
	var dist := flat.length()
	var move_x := 0.0
	var move_y := 0.0
	var buttons := 0
	if dist > 0.001:
		bot["yaw"] = atan2(to.x, to.z)
	if dist > d.SHOVEL_APPROACH:
		var n := flat / dist
		move_x = n.x; move_y = n.y
	# In build range + the shared cell is still empty -> drop the FOB site. The server rejects it if this
	# bot is not really the leader or the cell is occupied (harmless — another leader / a later tick lands it).
	if dist <= StructureStore.BUILD_RANGE - 0.5 and struct_at(structs, cell).is_empty():
		place_fob(bot, me, cell)
	if dist <= BuildSite.SHOVEL_RANGE:
		buttons |= InputCommand.BTN_SHOVEL   # advances the FOB site once placed; all same-team builders count
	d._send(bot, move_x, move_y, bot["yaw"], 0.0, buttons)

## Throw a FRAG at an in-view enemy when a structure sits roughly on the line between us and them
## (so the blast clears cover) — shared cooldown + per-bot frag cap. Drives the blast/destruction gate.
func maybe_grenade(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if int(bot["nades_thrown"]) >= d.MAX_BOT_GRENADES:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_grenade_tick"]) < d.GRENADE_COOLDOWN_TICKS:
		return
	if not cover_between(bot, me.pos, target.pos):
		return
	var dir := target.pos - me.pos
	if dir.length() < 0.001:
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_grenade_throw(dir.normalized(), Grenade.FRAG), 0)
	bot["last_grenade_tick"] = st
	bot["nades_thrown"] = int(bot["nades_thrown"]) + 1

## Throw a SMOKE toward the objective while advancing (no target) — shared cooldown + per-bot smoke
## cap. No gameplay effect until M7 LOS culling; exercises the smoke replication path for the gate.
func maybe_smoke(bot: Dictionary, me: EntityState, obj: Vector3) -> void:
	if int(bot["smokes_thrown"]) >= d.MAX_BOT_SMOKES:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_grenade_tick"]) < d.GRENADE_COOLDOWN_TICKS:
		return
	var dir := obj - me.pos
	if dir.length() < 0.001:
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_grenade_throw(dir.normalized(), Grenade.SMOKE), 0)
	bot["last_grenade_tick"] = st
	bot["smokes_thrown"] = int(bot["smokes_thrown"]) + 1

## Throw a FLASHBANG/IMPACT at a visible nearby enemy (M5.5-P3 gate exerciser). Shares the server
## throw cooldown + has a per-bot lifetime cap; aims directly at the target (flash blinds; impact
## detonates on contact).
func maybe_throwable(bot: Dictionary, me: EntityState, target: EntityState, type: int, count_key: String) -> void:
	if int(bot.get(count_key, 0)) >= d.MAX_BOT_SPECIAL_THROWS:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_grenade_tick"]) < d.GRENADE_COOLDOWN_TICKS:
		return
	var dir := target.pos - me.pos
	var dist := dir.length()
	if dist < 0.001 or dist > 30.0:
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_grenade_throw(dir.normalized(), type), 0)
	bot["last_grenade_tick"] = st
	bot[count_key] = int(bot.get(count_key, 0)) + 1

## Quick-knife when an enemy is at point-blank (M5.5-P3). Face the target so the server's
## frontal-cone selection picks it up; server cooldown-gates and resolves back-stab vs body damage.
func maybe_melee(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if me.pos.distance_to(target.pos) > Melee.MELEE_RANGE + 0.4:
		return
	var st: int = bot["server_tick"]
	if st - int(bot.get("last_melee_tick", -100000)) < d.MELEE_COOLDOWN_TICKS:
		return
	var to := target.pos - me.pos
	bot["yaw"] = atan2(to.x, to.z)
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, Protocol.encode_melee(), 0)
	bot["last_melee_tick"] = st

## Engineer sledgehammer exerciser: a subset of engineers (id % 4 == 0) steer to the nearest known
## structure and melee it in reach (the server demolishes the struck cell). Returns a [mx,my]
## movement override, or [] for bots that should drive normally. Best-effort — the deterministic
## gate proves the mechanic; this guarantees the fleet exercises it on building-dense maps.
func maybe_sledge(bot: Dictionary, me: EntityState) -> Array:
	if int(bot["class"]) != Loadout.ENGINEER or int(bot["id"]) % 4 != 0:
		return []
	var structs: Dictionary = bot["structs"]
	if structs.is_empty():
		return []
	var best_id := 0
	var best_d: float = d.SLEDGE_SEEK_RANGE
	for sid in structs:
		var wp: Vector3 = BuildGrid.world_of(structs[sid]["cell"] as Vector3i)
		var d := me.pos.distance_to(wp)
		if d < best_d:
			best_d = d; best_id = sid
	if best_id == 0:
		return []
	var to: Vector3 = BuildGrid.world_of(structs[best_id]["cell"] as Vector3i) - me.pos
	if to.length() <= Melee.MELEE_RANGE + 0.3:
		var st: int = bot["server_tick"]
		if st - int(bot.get("last_melee_tick", -100000)) >= d.MELEE_COOLDOWN_TICKS:
			bot["yaw"] = atan2(to.x, to.z); bot["pitch"] = 0.0
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, Protocol.encode_melee(), 0)
			bot["last_melee_tick"] = st
		return [0.0, 0.0]   # hold position while demolishing
	var f := Vector2(to.x, to.z).normalized()
	bot["yaw"] = atan2(f.x, f.y)
	return [f.x, f.y]

## Exercise fire-mode cycling and secondary weapon swap for a deterministic subset of bots.
## Fire-mode: the BotRoles.FIREMODE cohort (not Engineer, which uses SMG that lacks BURST)
## send MODE_BURST once per bot life (on first invocation after spawn, gated by fire_mode_set).
## Swap: the BotRoles.SWAP cohort swaps to secondary at server_tick % 600 == 120 and back at
## server_tick % 600 == 240 — guaranteed within the first ~10s of any match.
func maybe_weapon_handling(bot: Dictionary, me: EntityState) -> void:
	# Reset per-life flag when bot is not alive (called only when alive, but fire_mode_set
	# is also reset in the dead-bot branch via the respawn reset block, mirroring other flags).
	# Fire-mode: the BotRoles.FIREMODE cohort, non-Engineer only (AR supports BURST; SMG does not).
	if Roles.of(int(bot["index"])) == Roles.FIREMODE and int(bot["class"]) != Loadout.ENGINEER:
		if not bool(bot.get("fire_mode_set", false)):
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_set_fire_mode(Weapon.MODE_BURST), 0)
			bot["fire_mode_set"] = true
	# Periodic secondary swap: the BotRoles.SWAP cohort — now DISJOINT from the drillers (the old
	# %4==0 population was exactly the two driller cohorts, so no plain rifleman ever swapped and
	# drillers kept having the shovel yanked away mid-drill). Transition-based (send only on a slot
	# change) so it is robust to server_tick advancing by SNAPSHOT_STRIDE.
	if Roles.of(int(bot["index"])) == Roles.SWAP:
		var cycle: int = (int(bot["server_tick"]) / 120) % 4
		var want_slot: int = 1 if cycle == 1 else 0
		if want_slot != int(bot.get("cur_swap_slot", 0)):
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_swap_weapon(want_slot), 0)
			bot["cur_swap_slot"] = want_slot

## Engineer RPG is anti-vehicle first; falls back to targeting nearby structural building pieces
## (building_id != 0) near the bot's current objective when no enemy vehicle is in range.
## Estimate the vehicle target's velocity from successive snapshots and lead the aim by the
## rocket's flight time so a moving transport actually gets hit. Cooldown-gated (the server also
## enforces the real per-rocket cooldown + the 3-rocket reserve).
func maybe_rpg(bot: Dictionary, me: EntityState) -> void:
	if Loadout.bot_gadget(int(bot["id"]), int(bot["class"])) != Loadout.GADGET_RPG: return
	var vveh := AiVehicleCrew.nearest_enemy_vehicle(bot["vview"], bot["view"], me.pos, int(me.team), d.VEHICLE_RPG_RANGE)
	if vveh != 0:
		var vv: VehicleState = bot["vview"][vveh]
		var now := int(bot["server_tick"])
		# Update the velocity estimate for this vehicle (only when its position actually advanced).
		var track: Dictionary = bot["vveh_track"]
		var prev = track.get(vveh)
		var vel := Vector3.ZERO
		if prev != null:
			vel = prev["vel"]   # persist last good estimate between snapshots
			var dt_ticks := now - int(prev["tick"])
			var moved: Vector3 = vv.pos - (prev["pos"] as Vector3)
			if dt_ticks > 0 and moved.length() > 0.01:
				vel = moved / (float(dt_ticks) * SimLoop.DT)
		if prev == null or (vv.pos - (prev["pos"] as Vector3)).length() > 0.01:
			track[vveh] = {"pos": vv.pos, "tick": now, "vel": vel}
		# Cooldown gate (do the aim/fire only when ready).
		if now - int(bot["rpg_last_tick"]) < d.RPG_FIRE_COOLDOWN: return
		var origin := me.pos
		var flight: float = origin.distance_to(vv.pos) / d.ROCKET_SPEED
		# Lead the target, then raise the aim by 1/2 g t^2 so the ballistic rocket's arc passes
		# through it (rockets fall under d.ROCKET_GRAVITY; a flat aim lands short at range).
		var aim_pt: Vector3 = vv.pos + vel * flight
		aim_pt.y += 0.5 * d.ROCKET_GRAVITY * flight * flight
		# One refinement pass: the raised aim is slightly farther, so recompute flight + drop.
		flight = origin.distance_to(aim_pt) / d.ROCKET_SPEED
		aim_pt = vv.pos + vel * flight
		aim_pt.y += 0.5 * d.ROCKET_GRAVITY * flight * flight
		var dir := aim_pt - origin
		if dir.length() < 0.001: return
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE, Vector3.ZERO, dir.normalized(), 0), 0)
		bot["rpg_last_tick"] = now
		return
	# Fallback: no enemy vehicle in range — lob a rocket at the nearest structural building piece
	# (building_id != 0) within RPG range. This is a best-effort heuristic to help bots chip away
	# at destructible cover near contested points. Strictly additive; does NOT alter vehicle logic.
	maybe_rpg_building(bot, me)

## Which structural building piece (building_id != 0) within `rpg_range` of `my_pos` to rocket:
## PREFER the nearest piece a visible enemy is using as cover (an enemy within `enemy_radius` of it) —
## the tactical, BattleBit-like reason to fire — and only fall back to the nearest piece overall when
## no enemy-occupied piece is in range. Returns its sid, or 0 when no structural piece is in range.
## The map-chewing balance lever (bot-ai.md §8) is the CADENCE (RPG_STRUCTURE_COOLDOWN), not this
## target pick — the fallback keeps the destruction mechanic exercised on sparse maps. Pure + tested.
static func rpg_structure_target(structs: Dictionary, enemy_positions: Array, my_pos: Vector3, rpg_range: float, enemy_radius: float) -> int:
	var near_id := 0            # nearest structural piece overall (fallback)
	var near_d := rpg_range
	var cover_id := 0           # nearest structural piece an enemy is using as cover (preferred)
	var cover_d := rpg_range
	for sid in structs:
		var rec: Dictionary = structs[sid]
		if int(rec.get("building_id", 0)) == 0:
			continue   # skip non-building pieces (sandbags / cover props)
		var wp: Vector3 = BuildGrid.world_of(rec["cell"])
		var dist := my_pos.distance_to(wp)
		if dist >= rpg_range:
			continue
		if dist < near_d:
			near_d = dist; near_id = sid
		if dist < cover_d:
			for ep in enemy_positions:
				if (ep as Vector3).distance_to(wp) <= enemy_radius:
					cover_d = dist; cover_id = sid
					break
	return cover_id if cover_id != 0 else near_id

## Fallback for maybe_rpg: rocket a structural piece (preferring one an enemy is using as cover) with
## rocket-drop compensation. The map-chewing fix (bot-ai.md §8) is the much longer structure cadence
## here vs the anti-vehicle path — 5× slower than RPG_FIRE_COOLDOWN — plus the enemy-cover preference
## so the rockets that DO fly concentrate on contested cover instead of random walls.
func maybe_rpg_building(bot: Dictionary, me: EntityState) -> void:
	var now := int(bot["server_tick"])
	if now - int(bot["rpg_struct_last_tick"]) < d.RPG_STRUCTURE_COOLDOWN: return
	var structs: Dictionary = bot["structs"]
	if structs.is_empty(): return
	# Visible enemy positions (other team, alive, not downed) — steers the enemy-cover preference.
	var enemy_positions: Array = []
	var view: Dictionary = bot["view"]
	for id in view:
		if int(id) == int(bot["id"]): continue
		var e: EntityState = view[id]
		if e != null and e.alive and not e.is_downed and e.team != me.team:
			enemy_positions.append(e.pos)
	var best_id := rpg_structure_target(structs, enemy_positions, me.pos, d.VEHICLE_RPG_RANGE, d.RPG_STRUCTURE_ENEMY_RADIUS)
	if best_id == 0: return   # no enemy-occupied structural piece in range
	var target_cell: Vector3i = structs[best_id]["cell"]
	var target_wp: Vector3 = BuildGrid.world_of(target_cell)
	var origin := me.pos
	var flight: float = origin.distance_to(target_wp) / d.ROCKET_SPEED
	# Apply the same ballistic drop compensation as the vehicle path — raise the aim so the
	# rocket's arc passes through the target rather than falling short.
	var aim_pt := target_wp
	aim_pt.y += 0.5 * d.ROCKET_GRAVITY * flight * flight
	# One refinement pass (mirrors vehicle path).
	flight = origin.distance_to(aim_pt) / d.ROCKET_SPEED
	aim_pt = target_wp
	aim_pt.y += 0.5 * d.ROCKET_GRAVITY * flight * flight
	var dir := aim_pt - origin
	if dir.length() < 0.001: return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE, Vector3.ZERO, dir.normalized(), 0), 0)
	bot["rpg_last_tick"] = now
	bot["rpg_struct_last_tick"] = now   # separate, longer structure cadence (map-chewing restraint)

## Engineer C4: an engineer who chose C4 (bot_gadget → C4) places one near a structure
## between us and the enemy, then detonates it next pass.
func maybe_c4(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if Loadout.bot_gadget(int(bot["id"]), int(bot["class"])) != Loadout.GADGET_C4: return
	if not bool(bot["c4_placed"]):
		if not cover_between(bot, me.pos, target.pos): return
		var place := me.pos + (target.pos - me.pos).normalized() * 2.0
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_C4_PLACE, place, Vector3.ZERO, 0), 0)
		bot["c4_placed"] = true
	elif not bool(bot["c4_detonated"]):
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_C4_DETONATE, Vector3.ZERO, Vector3.ZERO, 0), 0)
		bot["c4_detonated"] = true

## Engineer claymore: an engineer who chose the claymore (bot_gadget → MINE) drops one
## facing `toward` (the current enemy when fighting, else the contested objective) — the claymore
## sits between the engineer and where enemies advance from, so an attacker (or the bot's own
## killer pushing in) crosses the 1.5 m trip cone. Re-placed each life (flags reset on death),
## so claymores keep appearing along the front rather than one stale one per match.
## NOTE: no bot loadout ever carries GADGET_MINE (claymore removed, spec §M), so this handler is
## permanently inert — kept only so its caller/references don't break.
func maybe_mine(bot: Dictionary, me: EntityState, toward: Vector3) -> void:
	if Loadout.bot_gadget(int(bot["id"]), int(bot["class"])) != Loadout.GADGET_MINE or bool(bot["mine_placed"]): return
	var to_t := Vector3(toward.x - me.pos.x, 0.0, toward.z - me.pos.z)
	var face := to_t.normalized() if to_t.length() > 0.001 else Vector3(sin(me.yaw), 0.0, cos(me.yaw))
	# Place toward `toward`, within the server's 2.0 m place_range.
	var place := me.pos + face * minf(1.8, maxf(to_t.length(), 0.001))
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_gadget_action(Protocol.GA_MINE_PLACE, place, face, 0), 0)
	bot["mine_placed"] = true

## M19 P2b Task 6: Engineer structure REPAIR — an engineer who chose REPAIR (bot_gadget → REPAIR)
## aims at the nearest known structure piece within repair range and latches GA_REPAIR_START,
## releasing once nothing is in range. Harmless by construction: the server's step_repairs/
## repair_chunks is a no-op on an already-full piece, so holding this on is never map-damaging —
## unlike BREACH/RPG there is no cadence gate here, only a range gate.
func maybe_repair_structure(bot: Dictionary, me: EntityState) -> void:
	if Loadout.bot_gadget(int(bot["id"]), int(bot["class"])) != Loadout.GADGET_REPAIR: return
	var structs: Dictionary = bot["structs"]
	var best_wp := Vector3.ZERO
	var best_d: float = d.REPAIR_STRUCT_RANGE
	var found := false
	for sid in structs:
		var wp: Vector3 = BuildGrid.world_of(structs[sid]["cell"] as Vector3i)
		var dist := me.pos.distance_to(wp)
		if dist < best_d:
			best_d = dist; best_wp = wp; found = true
	if not found:
		if bool(bot.get("struct_repairing", false)):
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_gadget_action(Protocol.GA_REPAIR_STOP, Vector3.ZERO, Vector3.ZERO, 0), 0)
			bot["struct_repairing"] = false
		return
	var to := best_wp - me.pos
	if to.length() > 0.001:
		bot["yaw"] = atan2(to.x, to.z)
	if not bool(bot.get("struct_repairing", false)):
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_REPAIR_START, Vector3.ZERO, Vector3.ZERO, 0), 0)
		bot["struct_repairing"] = true

## M19 P2b Task 6: Assault BREACH, kept deliberately RARE (project memory: bots previously
## over-rocketed and chewed the map with RPGs — BREACH must not repeat that). Only fires when
## (a) the per-bot MATCH-lifetime cap (d.MAX_BOT_BREACHES) and a long cooldown (d.BREACH_COOLDOWN_TICKS,
## stricter than the RPG structure cadence) both allow it, (b) a known structure piece sits within
## the gadget's own place range (so the server's place-range + aim-raycast gates would actually
## accept it), AND (c) a structure genuinely sits on the line between the bot and its objective —
## i.e. a wall is directly blocking its own march, not an arbitrary nearby piece.
func maybe_breach(bot: Dictionary, me: EntityState, obj: Vector3) -> void:
	if Loadout.bot_gadget(int(bot["id"]), int(bot["class"])) != Loadout.GADGET_BREACH: return
	if int(bot.get("breaches_placed", 0)) >= d.MAX_BOT_BREACHES: return
	var st: int = bot["server_tick"]
	if st - int(bot.get("breach_last_tick", -100000)) < d.BREACH_COOLDOWN_TICKS: return
	if not cover_between(bot, me.pos, obj): return   # a wall must actually block the path to the objective
	var structs: Dictionary = bot["structs"]
	var best_wp := Vector3.ZERO
	var best_d: float = d.BREACH_PLACE_RANGE
	var found := false
	for sid in structs:
		var wp: Vector3 = BuildGrid.world_of(structs[sid]["cell"] as Vector3i)
		var dist := me.pos.distance_to(wp)
		if dist < best_d:
			best_d = dist; best_wp = wp; found = true
	if not found: return   # nothing close enough for the server's place-range gate to accept
	var dir := best_wp - me.pos
	if dir.length() < 0.001: return
	var face := dir.normalized()
	var place := me.pos + face * best_d
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_gadget_action(Protocol.GA_BREACH_PLACE, place, face, 0), 0)
	bot["breach_last_tick"] = st
	bot["breaches_placed"] = int(bot.get("breaches_placed", 0)) + 1

const GIVE_RANGE := 3.0

## Pure give-target pick: nearest same-team mate within GIVE_RANGE that is alive,
## not downed (revive handles those) and actually HURT. Full-HP mates return 0 —
## the old version picked any alive mate, aim-locking medics onto healthy teammates.
static func give_pick(view: Dictionary, my_id: int, team: int, my_pos: Vector3) -> int:
	var best := 0
	var best_d := GIVE_RANGE
	for id in view:
		if int(id) == my_id: continue
		var e: EntityState = view[id]
		if not e.alive or e.is_downed or e.team != team or e.health >= 100: continue
		var d: float = my_pos.distance_to(e.pos)
		if d <= best_d:
			best_d = d; best = int(id)
	return best

## Medic/Support: if a same-team mate within give range is HURT (and we're not in a
## firefight), aim at them and latch the active give; also throw a bag the first time so
## the thrown-bag path is exercised. GIVE_START is sent once per target acquisition — the
## server latches it (`_giving`) and raycasts our aim each tick, so per-tick re-sends were
## pure packet spam. While `engaged`, combat keeps the aim and any latched give is stopped.
func maybe_give(bot: Dictionary, me: EntityState, engaged: bool) -> void:
	if bot["class"] != Loadout.MEDIC and bot["class"] != Loadout.SUPPORT: return
	var view: Dictionary = bot["view"]
	var best := 0 if engaged else give_pick(view, int(bot["id"]), me.team, me.pos)
	if best == 0:
		if int(bot.get("give_target", 0)) != 0:
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_gadget_action(Protocol.GA_GIVE_STOP, Vector3.ZERO, Vector3.ZERO, 0), 0)
			bot["give_target"] = 0
		return
	var tpos: Vector3 = (view[best] as EntityState).pos
	var aim := tpos - me.pos
	bot["yaw"] = atan2(aim.x, aim.z)
	bot["pitch"] = clampf(asin(clampf(aim.y / maxf(aim.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
	if int(bot.get("give_target", 0)) != best:
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_GIVE_START, Vector3.ZERO, aim.normalized(), best), 0)
		bot["give_target"] = best
	if int(bot["gave_until"]) == 0:
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_BAG_THROW, tpos, Vector3.ZERO, 0), 0)
		bot["gave_until"] = 1

## True if any known structure's cell-centre lies near the segment from `a` to `b` (coarse: the
## bot only knows piece positions from its mirror, not exact AABBs). Bounds the throw to useful cases.
func cover_between(bot: Dictionary, a: Vector3, b: Vector3) -> bool:
	var seg := b - a
	var seg_len := seg.length()
	if seg_len < 0.001:
		return false
	var n := seg / seg_len
	for id in bot["structs"]:
		var cell: Vector3i = bot["structs"][id]["cell"]
		var c := BuildGrid.cell_min(cell) + Vector3.ONE * (BuildGrid.CELL_SIZE * 0.5)
		var t := clampf((c - a).dot(n), 0.0, seg_len)
		if (a + n * t).distance_to(c) <= BuildGrid.CELL_SIZE:   # within ~one cell of the line
			return true
	return false

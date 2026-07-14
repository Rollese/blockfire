class_name ServerEmplacement
extends RefCounted
## Server-side LMG-nest pipeline (M19 P4): deploy (this task) + mount/dismount/fire/destroy (later
## tasks), plus the EMPLACEMENT_LIST render broadcast. Owns the live nest store; all decisions defer
## to Emplacement static rules so server authority matches client prediction / tests. Modeled on
## server/support.gd (RefCounted with a `srv` back-ref).

const Terrain := preload("res://shared/sim/terrain.gd")
const MAX_NESTS := 64   # explicit render-list bound (GadgetList.MAX precedent); nests are one-per-owner.

var srv                        # ServerMain back-ref (or EmplacementHarness in tests)
var nests: Dictionary = {}     # id -> Emplacement
var _next_index := 0

func _init(server) -> void:
	srv = server

func _def() -> Dictionary:
	return srv._gadgets.def_of_kind(Gadget.KIND_LMG_NEST)

## Deploy at the owner's aim point/facing. Validates the gadget is equipped, ground-snaps, enforces
## min separation from other nests, and one-active-nest-per-owner.
func deploy(owner_id: int, p: Pawn, pos: Vector3, dir: Vector3) -> void:
	if p == null: return
	var c = srv._clients.get(owner_id)
	if c == null or int(c["loadout"]["gadget"]) != Loadout.GADGET_LMG_NEST: return
	if dir.length() < 0.001: return
	var def := _def()
	var snapped := pos
	snapped.y = Terrain.height_at(srv._sim.terrain, snapped.x, snapped.z)
	# one active nest per owner: drop the owner's prior nest(s) FIRST so a redeploy near your own
	# current nest isn't blocked by the separation check below.
	for eid in nests.keys():
		if int((nests[eid] as Emplacement).owner_id) == owner_id:
			nests.erase(eid)
	# separation now only guards against OTHER owners' nests
	for e: Emplacement in nests.values():
		if e.alive and e.pos.distance_to(snapped) < float(def.get("min_sep_m", 4.0)):
			return
	var facing := atan2(dir.x, dir.z)
	var e := Emplacement.make(Emplacement.id_for(_next_index), Gadget.KIND_LMG_NEST, p.team, snapped, facing, def)
	e.owner_id = owner_id
	nests[e.id] = e
	_next_index += 1
	srv._stats.nests_deployed += 1

func get_nest(nest_id: int) -> Emplacement:
	return nests.get(nest_id)

## Rebuild the render list from live state (self-healing). Bounded by MAX_NESTS.
func build_list() -> Array:
	var out: Array = []
	for e: Emplacement in nests.values():
		if not e.alive: continue
		if out.size() >= MAX_NESTS: break
		out.append({"id": e.id, "pos": e.pos, "facing_yaw": e.facing_yaw, "turret_yaw": e.turret_yaw,
			"hp_frac": float(e.hp) / float(maxi(1, e.max_hp)), "occupant": e.occupant, "team": e.team})
	return out

## Bind a pawn to a nest seat (server authority). Defers to Emplacement.can_mount for all validity
## (alive/unmanned/same-team/in-range/not-already-mounted), so client prediction and tests agree.
func mount(id: int, p: Pawn, nest_id: int) -> void:
	var e: Emplacement = nests.get(nest_id)
	if e == null or p == null: return
	var mr := float(_def().get("mount_range_m", 1.6))
	if not Emplacement.can_mount(e, p, p.pos.distance_to(e.seat_world()), mr): return
	e.occupant = id
	p.mounted_nest = nest_id
	srv._stats.nests_manned += 1

func dismount(id: int, p: Pawn) -> void:
	if p == null or p.mounted_nest == 0: return
	var e: Emplacement = nests.get(p.mounted_nest)
	if e != null and e.occupant == id:
		e.occupant = 0
		p.pos = _safe_exit(e)
	p.mounted_nest = 0

## Step to the side of the seat, clear of the gun (nests deploy in the open, so a fixed side offset suffices).
func _safe_exit(e: Emplacement) -> Vector3:
	var side := Emplacement.yaw_forward(e.facing_yaw + PI * 0.5)
	var cand := e.seat_world() + side * 1.2
	cand.y = maxf(0.0, Terrain.height_at(srv._sim.terrain, cand.x, cand.z))
	return cand

## Per-tick: slave each occupant to the seat and mirror its (clamped) aim onto the turret. Run this
## AFTER pawn movement integration and BEFORE the nest-fire step, so the MG fires along fresh aim.
func step_occupants() -> void:
	var def := _def()
	var half_arc := deg_to_rad(float(def.get("half_arc_deg", 45)))
	var pit_lo := deg_to_rad(float(def.get("pitch_lo_deg", 20)))
	var pit_hi := deg_to_rad(float(def.get("pitch_hi_deg", 25)))
	for e: Emplacement in nests.values():
		# NOTE: death-eject (clearing a manning gunner's p.mounted_nest when a nest is destroyed) is
		# the damage path's job (ServerEmplacement.damage, Task 9), not here — dead nests are skipped.
		if not e.alive or e.occupant == 0: continue
		var p: Pawn = srv._sim.world.get_pawn(e.occupant)
		if p == null or not p.alive or p.is_downed or p.mounted_nest != e.id:
			e.occupant = 0
			if p != null and p.mounted_nest == e.id: p.mounted_nest = 0
			continue
		p.pos = e.seat_world()
		p.stance = Stance.PRONE   # G3a: a manned MG nest poses its gunner prone (pawn.step skips stance while
		                          # mounted, so we own it here); dismount/eject clears mounted_nest and the
		                          # next pawn.step restores normal stance control (never stuck prone).
		e.turret_yaw = Emplacement.clamp_yaw(p.yaw, e.facing_yaw, half_arc)
		e.pitch = Emplacement.clamp_pitch(p.pitch, pit_lo, pit_hi)
		p.yaw = e.turret_yaw   # reflect the clamped aim onto the pawn so this tick's snapshot yaw matches the turret (client mirrors the clamp locally)

## Fire step for every manned nest whose gunner holds fire (read from the occupant's last_input, like
## ServerFire.resolve_vehicle_fires). Heat accrues while HOLDING the trigger (not per-shot) so sustained
## fire overheats on the balance clock; the belt depletes per shot; an empty belt triggers a reload.
## Delegates hit resolution to ServerFire.emplacement_hitscan (lag-comp + LOS + damage) — stubbed in tests.
func step_fire() -> void:
	var def := _def()
	var interval := float(def.get("fire_interval", 0.075))
	var dmg := int(def.get("mg_damage", 22))
	var rng := float(def.get("range_m", 220.0))
	var supp := float(def.get("suppression", 1.0))
	var belt := int(def.get("belt", 150))
	var reload_ticks := int(def.get("reload_ticks", 135))
	var overheat_ticks := int(def.get("overheat_ticks", 90))
	var cooldown_ticks := int(def.get("cooldown_ticks", 90))
	var tick: int = srv._sim.tick
	for e: Emplacement in nests.values():
		if not e.alive or e.occupant == 0: continue
		var c = srv._clients.get(e.occupant)
		var inp = (c["last_input"] if c != null else null)
		var want := inp != null and (int(inp.get("buttons", 0)) & InputCommand.BTN_FIRE) != 0
		# reload state machine
		if e.ammo <= 0 and e.reloading_until == 0:
			e.reloading_until = tick + reload_ticks
		if e.reloading_until != 0 and tick >= e.reloading_until:
			e.ammo = belt
			e.reloading_until = 0
		var reloading := e.reloading_until != 0
		# heat integrates from the INTENT to fire (holding), gated by reload; heat_step's own locked
		# branch handles the already-overheated case, so passing `holding` is safe.
		var holding := want and not reloading
		var hs := Emplacement.heat_step(e.heat, e.overheated_until, tick, holding, overheat_ticks, cooldown_ticks)
		e.heat = int(hs["heat"]); e.overheated_until = int(hs["overheated_until"])
		# an actual round leaves the barrel only if holding, not overheated (post-step), belt has ammo,
		# and the fire interval elapsed since the last shot.
		var can_fire := holding and not Emplacement.overheated(e.overheated_until, tick) \
			and e.ammo > 0 and (float(tick - e.last_fire_tick) * SimLoop.DT >= interval)
		if not can_fire: continue
		e.last_fire_tick = tick
		e.ammo -= 1
		var origin := e.muzzle()
		var dir := Combat._forward(e.turret_yaw, e.pitch)
		srv._fire.emplacement_hitscan(e.occupant, e.team, origin, dir, dmg, rng, supp)

const DESTROY_BLAST_DMG := 60   # knock-off blast a manned nest's destruction deals its gunner

# Destruction vectors: explosives (via _blast_at), the exposed gunner (normal pawn fire),
# small-arms bullet-chip (ServerFire.step_projectiles → damage(), enemy-only, non-blocking), and
# the sledgehammer (server_main melee → damage(), team-agnostic). All route through damage() below.

## Apply `amount` damage to a nest by id (explosives route here via splash(); the future bullet/sledge
## paths will call this too). On death, EJECT the gunner (clear the seat binding) and, if it was manned,
## deal a knock-off blast so destroying a manned nest punishes the gunner. `attacker_id` credits it.
## The next EMPLACEMENT_LIST self-heals the removed entity on clients (build_list skips dead nests).
func damage(nest_id: int, amount: int, attacker_id: int) -> void:
	var e: Emplacement = nests.get(nest_id)
	if e == null or not e.alive: return
	var occ := e.occupant
	e.hit(amount, srv._sim.tick)   # floors hp; on death sets alive=false, occupant=0
	if not e.alive: srv._stats.nests_destroyed += 1
	if not e.alive and occ != 0:
		var p: Pawn = srv._sim.world.get_pawn(occ)
		if p != null:
			p.mounted_nest = 0                       # always eject
			# punish only a still-living gunner: the direct pawn-splash in _blast_at runs BEFORE this and
			# may already have killed the gunner (pos == seat == blast centre); re-hitting a dead pawn would
			# double the kill cascade. Mirror _destroy_vehicle's `p.alive` guard.
			if p.alive:
				# real signature: _apply_pawn_damage(vid, victim:Pawn, dmg, headshot, source, killer_id, weapon_id)
				srv._apply_pawn_damage(occ, p, DESTROY_BLAST_DMG, false, Revive.Source.BLAST, attacker_id, 0)

## Radius damage from an explosion centre. `base_dmg`/`radius` are the explosion's pawn-damage + radius;
## nests take the explosive `pawn_dmg` splash from any ENEMY explosive (frag/RPG/C4/mine); friendly fire
## is off (same-team nests are skipped, matching _blast_at's pawn/vehicle sweeps).
func splash(center: Vector3, base_dmg: int, radius: float, attacker_id: int, team: int) -> void:
	for eid in nests.keys():
		var e: Emplacement = nests[eid]
		if not e.alive or e.team == team: continue
		var d := Grenade.falloff_damage(center, e.pos, base_dmg, radius)
		if d > 0:
			damage(eid, d, attacker_id)

## Drop all of an owner's nests (disconnect cleanup — mirrors the deploy-time owner eviction). Closes a
## pre-existing leak: nests were evicted on redeploy (one-per-owner) but never on disconnect (unlike C4/mines).
func remove_owner(owner_id: int) -> void:
	for eid in nests.keys():
		if int((nests[eid] as Emplacement).owner_id) == owner_id:
			nests.erase(eid)

func clear() -> void:
	nests.clear()
	_next_index = 0

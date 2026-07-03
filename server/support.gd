class_name ServerSupport
extends RefCounted
## Support pipeline, extracted from server_main (batch 5 D1): latched revives, RMB active
## give (heal/ammo), engineer vehicle repair, downed bleed-out, give-up / self-bandage /
## revive-action handlers. Owns the support latch state; damage/kill stay on the server
## (back-ref `srv`). The tick loop clears links_this_tick before the steps rebuild it, and
## SUPPORT_LIST/SELF_STATE read it/being_revived from here.

var srv   # ServerMain back-ref (untyped: server_main.gd declares no class_name)

var reviving := {}             # reviver_id -> target_id, latched by REVIVE_ACTION(active)
var revive_ticks := {}         # target_id -> accumulated revive ticks
var being_revived := {}        # target_id -> reviver_id this tick (drives the downed "being revived" UI)
var giving: Dictionary = {}    # giver_id -> tick the give began (latched; cleared on STOP/invalid)
var repairing := {}            # engineer_id -> true (latched)
var repair_heat := {}          # engineer_id -> int
var repair_cd := {}            # engineer_id -> cooldown_until tick
var links_this_tick: Array = []   # [{giver, target, kind}] the steps actually acted on


func _init(server) -> void:
	srv = server


func is_medic(id: int) -> bool:
	return srv._clients.has(id) and int(srv._clients[id]["class"]) == Loadout.MEDIC


func complete_revive(target_id: int) -> void:
	var p: Pawn = srv._sim.world.get_pawn(target_id)
	if p == null: return
	p.is_downed = false
	p.health = Revive.REVIVE_HP
	p.bleed_health = 0
	p.bleed_halted = false
	# Fresh start after a revive: clear the damage ledger so a later death's recap reflects the
	# lethal sequence (~one health bar), not damage accumulated across the whole life.
	if srv._clients.has(target_id):
		srv._clients[target_id]["dmg_ledger"] = {}
		for k in ["downed_by", "downed_by_weapon", "downed_by_hp", "downed_by_dist"]:
			srv._clients[target_id].erase(k)
	srv._stats.revives += 1
	# No ticket refund needed — DOWNED never spent one.

## Accumulate revive progress for downed teammates being held by an in-range, alive reviver.
## Revive intent is LATCHED — set by REVIVE_ACTION(active) and held in `reviving` across ticks
## until the revive ends — so a per-tick REVIVE_ACTION packet dropped under fleet input-starvation
## does NOT reset progress. Validity is re-checked each tick against authoritative state, so only the
## reviver actually leaving range interrupts the hold; the latch is dropped when the revive is over.
func step_revives() -> void:
	var active_targets := {}   # target_id -> reviver_id (one reviver advances a target per tick)
	var done: Array = []       # latched intents to drop: revive ended or can never succeed
	for reviver_id in reviving:
		var target_id: int = reviving[reviver_id]
		var rp: Pawn = srv._sim.world.get_pawn(reviver_id)
		var tp: Pawn = srv._sim.world.get_pawn(target_id)
		if tp == null or not tp.is_downed: done.append(reviver_id); continue          # target resolved
		if rp == null or not rp.alive or rp.is_downed: done.append(reviver_id); continue  # reviver can't
		if tp.team != rp.team: done.append(reviver_id); continue                       # enemy can't revive
		if rp.pos.distance_to(tp.pos) > Revive.REVIVE_RANGE: continue                  # transient: hold latch, no progress
		active_targets[target_id] = reviver_id
	being_revived = active_targets   # expose to the SELF_STATE send so the downed player sees it
	# Drop accumulated progress for downed targets with no in-range reviver this tick.
	for t in revive_ticks.keys():
		if not active_targets.has(t):
			revive_ticks.erase(t)
	# Advance + complete.
	for target_id in active_targets:
		var reviver_id: int = active_targets[target_id]
		links_this_tick.append({"giver": reviver_id, "target": target_id, "kind": SupportLinks.REVIVE})
		revive_ticks[target_id] = int(revive_ticks.get(target_id, 0)) + 1
		if revive_ticks[target_id] >= Revive.revive_ticks(is_medic(reviver_id)):
			complete_revive(target_id)
			revive_ticks.erase(target_id)
			done.append(reviver_id)
	for rid in done:
		reviving.erase(rid)

## RMB active give: each held giver raycasts from its aim at one teammate in range and heals
## (medic) or resupplies (support) at the active rate. Latched like revive — held in giving until
## GA_GIVE_STOP or invalidation.
func step_active_give() -> void:
	if giving.is_empty():
		return
	var done: Array = []
	for gid in giving:
		var giver: Pawn = srv._sim.world.get_pawn(gid)
		if giver == null or not giver.alive or giver.is_downed: done.append(gid); continue
		var kind := giver_kind(int(srv._clients[gid]["class"]))
		if kind == -1: done.append(gid); continue
		var gdef: Dictionary = srv._gadgets.def_of_kind(kind)
		var aim := Combat._forward(giver.yaw, giver.pitch)
		var rng := float(gdef["give_range"])
		# Find the nearest in-range teammate on the aim ray.
		var target := 0
		var best := INF
		for tid in srv._sim.world.pawns:
			if tid == gid: continue
			var t: Pawn = srv._sim.world.pawns[tid]
			# Downed teammates are handled by revive (P1), not give/resupply — skip them.
			if not t.alive or t.is_downed or t.team != giver.team: continue
			var d2 := giver.pos.distance_to(t.pos)
			if d2 <= rng and d2 < best and Gadget.give_hits(giver.eye_position(), aim, t.pos, t.stance, rng):
				best = d2; target = tid
		if target == 0: continue   # nothing to give to this tick; keep the latch
		if kind == Gadget.KIND_HEAL:
			give_heal(target, int(gdef["active_rate"]))
			links_this_tick.append({"giver": gid, "target": target, "kind": SupportLinks.HEAL})
		else:
			give_ammo(target, int(gdef["active_rate"]))
			links_this_tick.append({"giver": gid, "target": target, "kind": SupportLinks.AMMO})
	for gid in done:
		giving.erase(gid)

## Latched repair (like active-give): each held engineer near a friendly damaged vehicle restores
## REPAIR_RATE/tick. Unlimited but overheat-gated (no pool). See docs/specs/vehicles.md §6.
func step_repairs() -> void:
	if repairing.is_empty():
		return
	var rdef: Dictionary = srv._gadgets.def_of_kind(Gadget.KIND_REPAIR)
	var rate := int(rdef["rate"]); var rng := float(rdef["range"])
	var overheat := int(rdef["overheat_ticks"]); var cool := int(rdef["cooldown_ticks"])
	var done: Array = []
	for eid in repairing:
		var ep: Pawn = srv._sim.world.get_pawn(eid)
		if ep == null or not ep.alive or ep.is_downed:
			done.append(eid); continue
		var v := nearest_friendly_damaged_vehicle(ep, rng)
		var want := v != null
		var st := Gadget.repair_heat_step(int(repair_heat.get(eid, 0)), int(repair_cd.get(eid, 0)),
			srv._sim.tick, want, overheat, cool)
		repair_heat[eid] = int(st["heat"]); repair_cd[eid] = int(st["cooldown_until"])
		if int(st["cooldown_until"]) > 0 and want:
			srv._stats.repair_overheats += 1
		if bool(st["repairing"]) and v != null:
			var before := v.hp
			v.hp = mini(v.max_hp, v.hp + rate)
			srv._stats.repairs += v.hp - before
			links_this_tick.append({"giver": eid, "target": v.id, "kind": SupportLinks.REPAIR})
	for eid in done:
		repairing.erase(eid)

## Owner-facing repair-tool gauge fractions for pawn `id`: (heat 0..1 toward overheat, cooldown 0..1
## of the lockout remaining). Zero for non-engineers / not repairing (early-out skips the def lookup
## for the ~127 clients who aren't repairing). Feeds encode_self_state → M7 HUD heat gauge.
func repair_gauge_for(id: int) -> Vector2:
	var raw_heat := int(repair_heat.get(id, 0))
	var cd_ticks := maxi(0, int(repair_cd.get(id, 0)) - srv._sim.tick)
	if raw_heat <= 0 and cd_ticks <= 0:
		return Vector2.ZERO
	var rdef: Dictionary = srv._gadgets.def_of_kind(Gadget.KIND_REPAIR)
	var overheat := maxi(1, int(rdef["overheat_ticks"]))
	var cool := maxi(1, int(rdef["cooldown_ticks"]))
	return Vector2(clampf(float(raw_heat) / float(overheat), 0.0, 1.0), clampf(float(cd_ticks) / float(cool), 0.0, 1.0))

func nearest_friendly_damaged_vehicle(ep: Pawn, rng: float) -> Vehicle:
	var best: Vehicle = null
	var bestd := rng
	for vid in srv._sim.world.vehicles:
		var v: Vehicle = srv._sim.world.vehicles[vid]
		if not v.alive or v.team != ep.team or v.hp >= v.max_hp: continue
		var d := ep.pos.distance_to(v.pos)
		if d <= bestd:
			bestd = d; best = v
	return best

## Heals target by `rate` HP, capped at 100. No-op if dead or already full.
func give_heal(target_id: int, rate: int) -> void:
	var t: Pawn = srv._sim.world.get_pawn(target_id)
	if t == null or not t.alive or t.health >= 100: return
	t.health = mini(100, t.health + rate)
	srv._stats.heals += 1

## Ammo give at 1 mag per `period` ticks (active_rate is the period). Refills ammo + a bandage.
func give_ammo(target_id: int, period: int) -> void:
	if period <= 0 or srv._sim.tick % period != 0: return
	if not srv._clients.has(target_id): return
	var tc = srv._clients[target_id]
	var cap: int = int(Weapon.get_def(int(tc["weapon"]))["mag_size"])
	if int(tc["ammo"]) >= cap and pawn_bandages_full(target_id): return
	tc["ammo"] = cap
	var tp: Pawn = srv._sim.world.get_pawn(target_id)
	if tp != null:
		tp.bandage_count = Revive.bandage_count_for(is_medic(target_id))
	srv._stats.ammo_gives += 1

func pawn_bandages_full(id: int) -> bool:
	var p: Pawn = srv._sim.world.get_pawn(id)
	return p != null and p.bandage_count >= Revive.bandage_count_for(is_medic(id))

## Per-tick bleed for every downed pawn; bleed-out is a true death (spends a ticket).
func step_downed() -> void:
	for id in srv._clients:
		var p: Pawn = srv._sim.world.get_pawn(id)
		if p == null or not p.is_downed:
			continue
		p.bleed_health = Revive.bleed_step(p.bleed_health, p.bleed_halted)
		if Revive.is_bled_out(p.bleed_health):
			# Credit the attacker who downed the pawn (falls back to self if unknown).
			var c = srv._clients[id]
			srv._kill_pawn(id, p, int(c.get("downed_by", id)), int(c.get("downed_by_weapon", 0)), false, Revive.Source.BULLET)
			srv._stats.bleedouts += 1


func giver_kind(cls: int) -> int:
	var g := Loadout.gadget_for(cls)
	if g == Loadout.GADGET_HEAL: return Gadget.KIND_HEAL
	if g == Loadout.GADGET_AMMO: return Gadget.KIND_AMMO
	return -1


func handle_give_up(peer: ENetPacketPeer) -> void:
	var id = srv._peer_to_id.get(peer, 0)
	if id == 0 or not srv._clients.has(id): return
	var p: Pawn = srv._sim.world.get_pawn(id)
	if p == null or not p.alive or not p.is_downed: return
	var c = srv._clients[id]
	srv._kill_pawn(id, p, int(c.get("downed_by", id)), int(c.get("downed_by_weapon", 0)), false, Revive.Source.BULLET)
	srv._stats.bleedouts += 1

func handle_self_bandage(peer: ENetPacketPeer, _bytes: PackedByteArray) -> void:
	var id = srv._peer_to_id.get(peer, 0)
	if id == 0 or not srv._clients.has(id): return
	var p: Pawn = srv._sim.world.get_pawn(id)
	if p == null or not p.is_downed or p.bleed_halted: return
	if p.bandage_count <= 0: return
	p.bandage_count -= 1
	p.bleed_halted = true

func handle_revive_action(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = srv._peer_to_id.get(peer, 0)
	if id == 0 or not srv._clients.has(id): return
	var d := Protocol.decode_revive_action(bytes)
	if bool(d["active"]):
		reviving[id] = int(d["target"])
	else:
		reviving.erase(id)

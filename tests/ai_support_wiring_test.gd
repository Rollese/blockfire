extends TestCase
## M7.5-P3 Task 6: support behaviours wired through Perception -> AiDriver -> bot_driver.
## Pure/fabricated-input tests: perception fills the support WorldModel fields from
## SELF_STATE/GADGET_LIST/GRENADE_FX mirrors, decide() drives the new behaviours, and
## bot_driver._on_packet maintains the mirrors (no server, no sockets).

const AiDriver := preload("res://bots/ai/ai_driver.gd")
const Protocol := preload("res://shared/net/protocol.gd")

func _es(team: int, pos: Vector3, alive := true, downed := false, hp := 100) -> EntityState:
	var e := EntityState.new()
	e.team = team; e.pos = pos; e.alive = alive; e.is_downed = downed; e.stance = 0; e.health = hp
	return e

# --- Perception fills the support fields -----------------------------------

func test_perception_fills_revive_target_from_downed_ally() -> void:
	var p := Perception.new()
	var view := {1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(8, 0, 0), true, true)}
	var w := p.build(1, view, {}, {}, [], 100)
	assert_eq(int(w.revive_target["id"]), 2, "close downed ally becomes the revive target")

func test_perception_revive_reach_depends_on_medic() -> void:
	var view := {1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(20, 0, 0), true, true)}
	var wn := Perception.new().build(1, view, {}, {}, [], 100, {}, [], [], false)
	assert_true(wn.revive_target.is_empty(), "20m downed ally is beyond non-medic reach")
	var wm := Perception.new().build(1, view, {}, {}, [], 100, {}, [], [], true)
	assert_eq(int(wm.revive_target["id"]), 2, "a medic commits to the 20m revive")

func test_perception_supply_kind_ammo_from_mag_fraction() -> void:
	var view := {1: _es(0, Vector3.ZERO)}
	var low := {"mag": 5, "weapon": Weapon.AR}   # 5/30 < BAG_SEEK_AMMO_FRAC
	var w := Perception.new().build(1, view, {}, {}, [], 100, low)
	assert_eq(w.supply_kind, "ammo", "low mag fraction wants an ammo bag")
	var full := {"mag": 30, "weapon": Weapon.AR}
	var w2 := Perception.new().build(1, view, {}, {}, [], 100, full)
	assert_eq(w2.supply_kind, "", "full mag + full hp needs nothing")

func test_perception_supply_kind_heal_on_low_hp() -> void:
	var view := {1: _es(0, Vector3.ZERO, true, false, 40)}   # hp_frac 0.4 < 0.55
	var w := Perception.new().build(1, view, {}, {}, [], 100, {"mag": 30, "weapon": Weapon.AR})
	assert_eq(w.supply_kind, "heal", "low hp wants a heal bag before ammo")

func test_perception_picks_nearest_bag_from_gadget_mirror() -> void:
	var view := {1: _es(0, Vector3.ZERO, true, false, 40)}
	var gadgets := [
		{"kind": GadgetList.BAG, "pos": Vector3(30, 0, 0), "face": Vector3.ZERO},
		{"kind": GadgetList.BAG, "pos": Vector3(6, 0, 0), "face": Vector3.ZERO},
		{"kind": GadgetList.C4, "pos": Vector3(1, 0, 0), "face": Vector3.ZERO},
	]
	var w := Perception.new().build(1, view, {}, {}, [], 100, {}, gadgets)
	assert_false(w.supply_bag.is_empty(), "a bag was picked")
	assert_almost_eq((w.supply_bag["pos"] as Vector3).x, 6.0, 0.001, "nearest bag wins; C4 ignored")

func test_perception_danger_zones_from_grenades_and_mines() -> void:
	var view := {1: _es(0, Vector3.ZERO)}
	var gadgets := [{"kind": GadgetList.MINE, "pos": Vector3(4, 0, 0), "face": Vector3.ZERO}]
	var events := [
		{"pos": Vector3(2, 0, 0), "tick": 90},    # fresh (now-90 <= 75)
		{"pos": Vector3(9, 0, 0), "tick": 0},     # stale (now-0 > 75) -> expired
	]
	var w := Perception.new().build(1, view, {}, {}, [], 100, {}, gadgets, events)
	assert_eq(w.danger_zones.size(), 2, "1 fresh grenade + 1 mine = 2 zones (stale grenade expired)")

# --- decide(): revive / seek_supply / avoid_danger --------------------------

func test_revive_behavior_moves_toward_target() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(10, 0, 0), true, true)}
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "revive", "downed ally in reach -> revive behaviour")
	assert_true(float(intent["move_x"]) > 0.5, "moves toward the downed ally (+x)")
	assert_eq(int(intent.get("revive_target_id", 0)), 0, "no revive latch while still out of range")

func test_revive_behavior_crouches_and_latches_in_range() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(0, Vector3(1.5, 0, 0), true, true)}
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO)
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "revive")
	assert_eq(int(intent.get("revive_target_id", 0)), 2, "in range -> intent carries the revive target")
	assert_eq(int(intent["stance"]), Stance.CROUCH, "crouch over the downed mate")
	assert_almost_eq(float(intent["move_x"]), 0.0, 0.001, "holds still while reviving")
	assert_almost_eq(float(intent["move_y"]), 0.0, 0.001, "holds still while reviving")

func test_seek_supply_moves_toward_bag() -> void:
	# Low AMMO at full hp isolates seek_supply from the pressure envelope (a first sighting
	# of a hurt self reads as a fresh health drop -> retreat/take_cover would win instead).
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO)}
	var low_ammo := {"mag": 5, "weapon": Weapon.AR}
	var gadgets := [{"kind": GadgetList.BAG, "pos": Vector3(20, 0, 0), "face": Vector3.ZERO}]
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO, [], low_ammo, gadgets)
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "seek_supply", "low ammo + known bag -> seek_supply")
	assert_true(float(intent["move_x"]) > 0.5, "moves toward the bag (+x)")

func test_seek_supply_stops_on_arrival() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO)}
	var low_ammo := {"mag": 5, "weapon": Weapon.AR}
	var gadgets := [{"kind": GadgetList.BAG, "pos": Vector3(1, 0, 0), "face": Vector3.ZERO}]   # < BAG_ARRIVE_RANGE
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO, [], low_ammo, gadgets)
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "seek_supply")
	assert_almost_eq(float(intent["move_x"]), 0.0, 0.001, "arrived: stand on the bag while it dispenses")
	assert_almost_eq(float(intent["move_y"]), 0.0, 0.001, "arrived: no movement")

func test_avoid_danger_flees_and_never_fires() -> void:
	var ai := AiDriver.new(42, 0, "regular")
	var view := {1: _es(0, Vector3.ZERO), 2: _es(1, Vector3(10, 0, 0))}
	var events := [{"pos": Vector3(2, 0, 0), "tick": 100}]
	ai.observe(1, view, {}, {}, [], 100, Vector3.ZERO, [], {}, [], events)
	ai.observe(1, view, {}, {}, [], 112, Vector3.ZERO, [], {}, [], events)   # enemy actionable now
	var intent := ai.decide()
	assert_eq(String(intent["behavior"]), "avoid_danger", "grenade underfoot overrides engage")
	assert_true(float(intent["move_x"]) < -0.5, "flees away from the grenade (-x)")
	assert_eq(int(intent["buttons"]), 0, "never fires while fleeing")

# --- bot_driver._on_packet mirrors ------------------------------------------

func test_on_packet_self_state_mirror() -> void:
	var bd := BotDriver.new()
	autofree(bd)
	var bot := {"server_tick": 500, "grenade_events": []}
	bd._on_packet(bot, Protocol.encode_self_state(12, false, 0, Weapon.AR, [], true, 0.0, 0, 2, false))
	var ss: Dictionary = bot["self_state"]
	assert_eq(int(ss["mag"]), 12, "ammo mirrored from SELF_STATE")
	assert_eq(int(ss["bandage_count"]), 2, "bandage count mirrored")
	assert_true(bool(ss["being_revived"]), "being_revived mirrored")

func test_on_packet_gadget_list_wholesale_replace() -> void:
	var bd := BotDriver.new()
	autofree(bd)
	var bot := {"server_tick": 500, "grenade_events": []}
	var l1 := [{"kind": GadgetList.MINE, "pos": Vector3(4, 0, 0), "face": Vector3.ZERO},
		{"kind": GadgetList.BAG, "pos": Vector3(8, 0, 0), "face": Vector3.ZERO}]
	bd._on_packet(bot, Protocol.encode_gadget_list(l1))
	assert_eq((bot["gadgets"] as Array).size(), 2, "mirror holds the full list")
	bd._on_packet(bot, Protocol.encode_gadget_list([]))
	assert_eq((bot["gadgets"] as Array).size(), 0, "authoritative list replaces wholesale")

func test_on_packet_grenade_fx_capped_landing_ring() -> void:
	var bd := BotDriver.new()
	autofree(bd)
	var bot := {"server_tick": 500, "grenade_events": []}
	for i in 10:
		bd._on_packet(bot, Protocol.encode_grenade_fx(Vector3(10 + i, 0, 0), Vector3(1, 0, 0), Grenade.FRAG))
	var events: Array = bot["grenade_events"]
	assert_eq(events.size(), 8, "ring capped at 8, oldest dropped")
	var newest: Dictionary = events[events.size() - 1]
	assert_true((newest["pos"] as Vector3).distance_to(Vector3(27, 0, 0)) < 0.2, "flat 8m-ahead landing estimate")
	assert_eq(int(newest["tick"]), 500, "stamped with the bot's server tick")
	# SMOKE arcs also ride GRENADE_FX but are harmless — they must not become danger input.
	bd._on_packet(bot, Protocol.encode_grenade_fx(Vector3.ZERO, Vector3(1, 0, 0), Grenade.SMOKE))
	assert_eq((bot["grenade_events"] as Array).size(), 8, "smoke throw ignored by the danger ring")

extends TestCase
## Quick-swap silhouette regression: `weapon` rides only the snapshot ENTER record, so a
## remote that kept the pawn in its interest set rendered the wrong held gun from the
## first SWAP_WEAPON until a LEAVE/ENTER cycle. Fix: the server drops the pawn from every
## client's stored baselines on swap (and on loadout reset), forcing a re-ENTER — which
## decode_apply applies in place, updating the weapon byte on the existing view entry.

func _state(weapon: int) -> EntityState:
	var e := EntityState.new()
	e.pos = Vector3(1, 0, 2); e.health = 90; e.weapon = weapon
	return e

func test_reenter_updates_weapon_on_existing_view_entry() -> void:
	# Baseline missing the id => ENTER record => weapon byte reaches a view that already
	# holds the entity (the wire mechanism the server-side fix relies on).
	var view := {}
	Snapshot.decode_apply(Snapshot.encode(10, 1, 0, 0, {7: _state(3)}, {}), view)
	assert_eq(int(view[7].weapon), 3, "initial ENTER carries the weapon")
	# Same entity, weapon changed, baseline STILL HAS the id: no weapon on the wire.
	Snapshot.decode_apply(Snapshot.encode(11, 2, 1, 0, {7: _state(5)}, {7: _state(3)}), view)
	assert_eq(int(view[7].weapon), 3, "CHANGED records cannot carry weapon (documents the gap)")
	# Baseline with the id erased (what _force_reenter does): re-ENTER updates in place.
	Snapshot.decode_apply(Snapshot.encode(12, 3, 2, 0, {7: _state(5)}, {}), view)
	assert_eq(int(view[7].weapon), 5, "forced re-ENTER refreshes the silhouette weapon")

func _slot(weapon: int) -> Dictionary:
	return {"weapon": weapon, "weapon_def": Weapon.get_def(weapon), "ammo": 30,
		"reserve": Weapon.reserve_ammo(weapon), "spare_mags": [], "reload_fast": false,
		"reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "fire_mode": Weapon.default_mode(weapon)}

func test_swap_weapon_forces_reenter_in_all_client_baselines() -> void:
	var srv = preload("res://server/server_main.gd").new()
	# Subject client 7 with a two-slot loadout, plus observer client 8 holding snapshot
	# history that contains pawn 7 in its baselines.
	var c := {"slots": [_slot(Weapon.AR), _slot(Weapon.PISTOL)], "active_slot": 0,
		"swap_locked_until": 0, "history": {3: {7: _state(Weapon.AR)}}, "history_v": {}}
	for f in srv._SLOT_FIELDS: c[f] = c["slots"][0][f]
	srv._clients[7] = c
	var obs := {"history": {5: {7: _state(Weapon.AR), 8: _state(Weapon.AR)}}, "history_v": {}}
	srv._clients[8] = obs
	srv._swap_weapon(7, 1)
	assert_eq(int(c["weapon"]), Weapon.PISTOL, "swap took effect")
	assert_false((obs["history"][5] as Dictionary).has(7), "observer baseline drops the swapper -> re-ENTER next send")
	assert_true((obs["history"][5] as Dictionary).has(8), "other entities untouched")
	assert_false((c["history"][3] as Dictionary).has(7), "own baseline drops it too (self silhouette path)")
	srv.free()

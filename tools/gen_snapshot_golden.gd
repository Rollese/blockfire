extends SceneTree
## Regenerates the snapshot golden vectors from the GDScript REFERENCE encoder.
## Run ONLY when the wire format deliberately changes (then bump VERSION and update
## both encoders first). Scenario is expressed in quantized column space.
## Run: godot --headless --path . --script tools/gen_snapshot_golden.gd

const TICKS := 40
const SEED := 20260710

func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var scenario := {"ticks": []}
	var expected := PackedByteArray()
	var truth := {}
	for i in 8: truth[i + 1] = _rand_fields(rng)
	var vtruth := {10001: _rand_vfields(rng)}
	var hist := {}
	var hist_v := {}
	var last_acked := 0
	for tick in TICKS:
		for id in truth: _mutate_fields(rng, truth[id])
		if tick == 15: truth.erase(2)
		if tick == 20: truth[99] = _rand_fields(rng)
		var trec := {"tick": tick, "pawns": {}, "vehicles": {}, "sends": []}
		for id in truth: trec["pawns"][str(id)] = (truth[id] as Array).duplicate()
		for vid in vtruth: trec["vehicles"][str(vid)] = (vtruth[vid] as Dictionary).duplicate(true)
		# one client, deterministic interest = all ids except a rotating skip every 3rd tick
		var current := {}
		var interest: Array = []
		var skip: int = truth.keys()[tick % truth.size()]
		for id in truth:
			if id == skip and tick % 3 == 0: continue
			interest.append(id)
			current[id] = _state_from(truth[id])
		var current_v := {}
		var vinterest: Array = []
		for vid in vtruth:
			vinterest.append(vid)
			current_v[vid] = _vstate_from(vtruth[vid])
		var bl_seq := last_acked
		var baseline = hist.get(bl_seq)
		if baseline == null:
			baseline = {}; bl_seq = 0
		var baseline_v = hist_v.get(bl_seq)
		if baseline_v == null:
			baseline_v = {}
		var seq := tick + 1
		var bytes := Snapshot.encode(tick, seq, bl_seq, tick * 2, current, baseline, current_v, baseline_v)
		trec["sends"].append({"cid": 7, "seq": seq, "want_baseline": last_acked,
			"lit": tick * 2, "interest": interest, "vinterest": vinterest, "len": bytes.size()})
		var lenb := PackedByteArray()
		lenb.resize(4)
		lenb.encode_u32(0, bytes.size())
		expected.append_array(lenb)
		expected.append_array(bytes)
		hist[seq] = current
		hist_v[seq] = current_v
		if tick % 2 == 0: last_acked = seq
		scenario["ticks"].append(trec)
	DirAccess.make_dir_recursive_absolute("res://tests/fixtures")
	var f := FileAccess.open("res://tests/fixtures/snapshot_golden_scenario.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(scenario))
	f.close()
	var fb := FileAccess.open("res://tests/fixtures/snapshot_golden_expected.bin", FileAccess.WRITE)
	fb.store_buffer(expected)
	fb.close()
	print("[golden] wrote %d ticks, %d expected bytes" % [TICKS, expected.size()])
	quit()

func _rand_fields(rng: RandomNumberGenerator) -> Array:
	return [rng.randi_range(-400000, 400000), rng.randi_range(-5000, 50000), rng.randi_range(-400000, 400000),
		rng.randi_range(0, 65535), rng.randi_range(0, 65535), rng.randi_range(0, 255),
		rng.randi_range(-10, 310), rng.randi_range(0, 260), rng.randi_range(0, 2), rng.randi_range(0, 5)]

func _mutate_fields(rng: RandomNumberGenerator, f: Array) -> void:
	if rng.randf() < 0.6: f[0] += rng.randi_range(-2000, 2000)
	if rng.randf() < 0.3: f[3] = rng.randi_range(0, 65535)
	if rng.randf() < 0.15: f[6] = rng.randi_range(-10, 310)
	if rng.randf() < 0.1: f[5] = rng.randi_range(0, 255)

func _rand_vfields(rng: RandomNumberGenerator) -> Dictionary:
	return {"f": [rng.randi_range(-300000, 300000), 0, rng.randi_range(-300000, 300000),
		rng.randi_range(0, 65535), rng.randi_range(0, 65535), rng.randi_range(-5, 70000), rng.randi_range(0, 3)],
		"seats": [rng.randi_range(1, 128)]}

func _state_from(f: Array) -> EntityState:
	var e := EntityState.new()
	e.q_px = f[0]; e.q_py = f[1]; e.q_pz = f[2]; e.q_yaw = f[3]; e.q_pitch = f[4]; e.q_state = f[5]
	e.health = f[6]; e.squad = f[7]; e.armor_class = f[8]; e.weapon = f[9]
	e.q_baked = true
	return e

func _vstate_from(d: Dictionary) -> VehicleState:
	var v := VehicleState.new()
	var f: Array = d["f"]
	v.q_px = f[0]; v.q_py = f[1]; v.q_pz = f[2]; v.q_heading = f[3]; v.q_turret = f[4]
	v.hp = f[5]; v.type = f[6]
	v.seats = (d["seats"] as Array).duplicate()
	v.q_baked = true
	return v

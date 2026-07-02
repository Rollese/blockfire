extends TestCase
## VehicleState.bake(): the vehicle delta path was pre-bake-era — _veh_diff_mask quantized
## both baseline and current per field per client-send, then _put_veh_fields re-quantized
## again (the exact ~3x pattern EntityState.bake() killed for pawns in M11). Must stay
## bit-identical to on-the-fly quantization.

func _vs(x: float, heading: float, turret: float) -> VehicleState:
	var v := VehicleState.new()
	v.pos = Vector3(x, 1.5, -20.0); v.heading = heading; v.turret_yaw = turret
	v.hp = 450; v.type = 0; v.seats = [7, 0, 0, 0, 9]
	return v

func test_bake_matches_on_the_fly_quantization() -> void:
	var v := _vs(123.456, 1.25, -0.5)
	v.bake()
	assert_true(v.q_baked, "baked flag set")
	assert_eq(v.q_px, Quantize.enc_pos(v.pos.x), "pos.x cache matches Quantize")
	assert_eq(v.q_py, Quantize.enc_pos(v.pos.y), "pos.y cache matches Quantize")
	assert_eq(v.q_pz, Quantize.enc_pos(v.pos.z), "pos.z cache matches Quantize")
	assert_eq(v.q_heading, Quantize.enc_angle(v.heading), "heading cache matches Quantize")
	assert_eq(v.q_turret, Quantize.enc_angle(v.turret_yaw), "turret cache matches Quantize")

func test_encode_bit_identical_and_roundtrips_via_baked_path() -> void:
	# Same current/baseline content encoded twice (fresh unbaked states each time) must be
	# byte-identical, and the delta must roundtrip into the same view as before the bake.
	var a := Snapshot.encode(50, 3, 2, 0, {}, {}, {1073741824: _vs(10.0, 0.5, 0.1)}, {1073741824: _vs(9.0, 0.5, 0.1)})
	var b := Snapshot.encode(50, 3, 2, 0, {}, {}, {1073741824: _vs(10.0, 0.5, 0.1)}, {1073741824: _vs(9.0, 0.5, 0.1)})
	assert_true(a == b, "deterministic bytes")
	var view_v := {}
	Snapshot.decode_apply(Snapshot.encode(49, 2, 0, 0, {}, {}, {1073741824: _vs(9.0, 0.5, 0.1)}, {}), {}, view_v)
	Snapshot.decode_apply(a, {}, view_v)
	assert_almost_eq((view_v[1073741824] as VehicleState).pos.x, 10.0, 0.11, "delta applies moved x")

func test_unchanged_vehicle_emits_no_record() -> void:
	var cur := {1073741824: _vs(10.0, 0.5, 0.1)}
	var base := {1073741824: _vs(10.0, 0.5, 0.1)}
	var bytes := Snapshot.encode(50, 3, 2, 0, {}, {}, cur, base)
	var view_v := {}
	var quiet := Snapshot.encode(50, 3, 2, 0, {}, {}, {}, {})
	assert_eq(bytes.size(), quiet.size(), "identical baked ints -> mask 0 -> record skipped")

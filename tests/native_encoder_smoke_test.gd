extends TestCase
## Loads the native encoder and checks a tiny keyframe against the GDScript reference.
## Skips when the .so is absent locally; FAILS when absent in CI (the parity gate must run there).

func _native_required() -> bool:
	if ClassDB.class_exists("NativeSnapshotEncoder"):
		return true
	if OS.get_environment("CI") != "":
		fail("NativeSnapshotEncoder missing in CI — cargo build step broken")
	else:
		print("[skip] native_encoder_smoke: .so not built (cargo build --release in native/snapshot_encoder)")
	return false

func test_keyframe_matches_reference() -> void:
	if not _native_required(): return
	var e1 := EntityState.new(); e1.pos = Vector3(10, 2, 20); e1.health = 90; e1.squad = 3
	var e2 := EntityState.new(); e2.pos = Vector3(-3, 0, 4); e2.weapon = 2; e2.armor_class = 1
	var current := {1: e1, 2: e2}
	var ref_bytes := Snapshot.encode(7, 1, 0, 99, current, {})
	var enc = ClassDB.instantiate("NativeSnapshotEncoder")
	enc.set_msg_id(Protocol.Msg.SNAPSHOT)
	var ids := PackedInt32Array([1, 2])
	var fields := PackedInt32Array()
	fields.resize(2 * SnapshotColumns.PAWN_STRIDE)
	var i := 0
	for id in current:
		var e: EntityState = current[id]
		e.bake()
		var o := i * SnapshotColumns.PAWN_STRIDE
		fields[o] = e.q_px; fields[o + 1] = e.q_py; fields[o + 2] = e.q_pz
		fields[o + 3] = e.q_yaw; fields[o + 4] = e.q_pitch; fields[o + 5] = e.q_state
		fields[o + 6] = e.health; fields[o + 7] = e.squad
		fields[o + 8] = e.armor_class; fields[o + 9] = e.weapon
		i += 1
	assert_true(enc.begin_tick(7, ids, fields, PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array([0])))
	var nat_bytes: PackedByteArray = enc.encode_for(42, 1, 0, 99, ids, PackedInt32Array())
	assert_eq(nat_bytes, ref_bytes, "native keyframe must byte-equal Snapshot.encode")
	# and the unchanged GDScript decoder must accept it
	var view := {}
	Snapshot.decode_apply(nat_bytes, view)
	assert_eq(view.size(), 2)
	assert_almost_eq(view[1].pos.x, 10.0, 0.01)

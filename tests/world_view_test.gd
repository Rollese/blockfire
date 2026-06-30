extends TestCase

func _state(x: float, team := 0) -> EntityState:
	var e := EntityState.new()
	e.pos = Vector3(x, 0, 0)
	e.team = team
	e.alive = true
	return e

# keyframe snapshot (baseline empty) with local id 1 at origin + remote id 2 at remote_x
func _snap(seq: int, remote_x: float) -> PackedByteArray:
	var current := {1: _state(0.0, 0), 2: _state(remote_x, 1)}
	return Snapshot.encode(100 + seq, seq, 0, seq, current, {})

func test_remotes_interpolate_excluding_self() -> void:
	var wv := WorldView.new()
	wv.set_local_id(1)
	wv.apply_snapshot(_snap(1, 0.0), 1.0)
	wv.apply_snapshot(_snap(2, 10.0), 1.1)
	var remotes := wv.remotes_at(1.15)   # render at 1.05 = halfway between the two
	assert_false(remotes.has(1), "local id excluded from remotes")
	assert_true(remotes.has(2), "remote id present")
	assert_almost_eq(remotes[2].pos.x, 5.0, 0.2, "remote lerped ~halfway")

func test_self_state_is_latest_authoritative() -> void:
	var wv := WorldView.new()
	wv.set_local_id(1)
	wv.apply_snapshot(_snap(1, 0.0), 1.0)
	var s := wv.self_state()
	assert_true(s != null, "self present after snapshot")
	assert_almost_eq(s.pos.x, 0.0, 0.1, "self authoritative pos")
	assert_eq(wv.last_header["last_input_tick"], 1, "header surfaced")

func test_structure_baseline_then_delta_add_remove() -> void:
	var wv := WorldView.new()
	wv.apply_structure_baseline(Protocol.encode_structure_baseline(Vector2i(0, 0), [
		{"id": 5, "type": 0, "cell": Vector3i(1, 0, 1), "yaw": 0, "chunks": ChunkMask.full_mask(8), "building_id": 0, "owner": 1}]))
	assert_true(wv.structures().has(5), "baseline piece present")
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": 5}))
	assert_false(wv.structures().has(5), "removed piece gone")

func test_structure_op_chunk_updates_mask() -> void:
	var wv := WorldView.new()
	wv.apply_structure_baseline(Protocol.encode_structure_baseline(Vector2i(0, 0), [
		{"id": 7, "type": 0, "cell": Vector3i(2, 0, 3), "yaw": 0, "chunks": ChunkMask.full_mask(8), "building_id": 0, "owner": 1}]))
	assert_true(wv.structures().has(7), "baseline piece present before chunk update")
	var newmask := ChunkMask.full_mask(8) & ~0b1111
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_CHUNK, {"id": 7, "mask": newmask}))
	assert_true(wv.structures().has(7), "record still exists after chunk update")
	assert_eq(wv.structures()[7]["chunks"], newmask, "chunk mask updated by OP_CHUNK")

func test_op_progress_updates_build_progress() -> void:
	# M12 client: an under-construction build site advances its build_progress via OP_PROGRESS
	# (the server only sends id+progress; the renderer derives the fill fraction from its catalog).
	var wv := WorldView.new()
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_PLACE,
		{"id": 12, "type": 0, "cell": Vector3i(3, 0, 4), "yaw": 0, "chunks": ChunkMask.full_mask(8),
		"building_id": 0, "owner": 1, "under_construction": 1, "build_progress": 0}))
	assert_true(wv.structures().has(12), "build site placed")
	assert_eq(int(wv.structures()[12]["under_construction"]), 1, "site flagged under construction")
	var v0 := wv.structs_version()
	wv.apply_structure_delta(Protocol.encode_structure_progress(12, 42))
	assert_eq(int(wv.structures()[12]["build_progress"]), 42, "build_progress advanced by OP_PROGRESS")
	assert_eq(int(wv.structures()[12]["under_construction"]), 1, "still under construction mid-build")
	assert_true(wv.structs_version() > v0, "OP_PROGRESS bumps the structs version so the renderer re-poses")

func test_op_progress_unknown_id_is_ignored() -> void:
	var wv := WorldView.new()
	wv.apply_structure_delta(Protocol.encode_structure_progress(999, 10))  # no such site
	assert_false(wv.structures().has(999), "progress for an unknown id must not create a record")

func test_collapse_drops_buildings_pieces() -> void:
	var wv := WorldView.new()
	wv._structs[1] = {"id": 1, "type": 2, "cell": Vector3i(0,0,0), "yaw": 0, "chunks": -1, "building_id": 7}
	wv._structs[2] = {"id": 2, "type": 2, "cell": Vector3i(0,1,0), "yaw": 0, "chunks": -1, "building_id": 7}
	wv._structs[3] = {"id": 3, "type": 1, "cell": Vector3i(9,0,0), "yaw": 0, "chunks": -1, "building_id": 0}
	wv.apply_collapse(7)
	assert_false(wv.structures().has(1), "building 7 piece dropped")
	assert_false(wv.structures().has(2), "building 7 piece dropped")
	assert_true(wv.structures().has(3), "loose piece kept")
	assert_eq(wv.take_collapsed(), [7], "collapsed building id queued for rubble spawn")

func test_collapse_zero_is_ignored() -> void:
	var wv := WorldView.new()
	wv._structs[3] = {"id": 3, "type": 1, "cell": Vector3i(9,0,0), "yaw": 0, "chunks": -1, "building_id": 0}
	wv.apply_collapse(0)
	assert_true(wv.structures().has(3), "apply_collapse(0) must NOT wipe loose pieces")
	assert_eq(wv.take_collapsed(), [], "no collapse queued for id 0")

# --- M11-P4: destruction cosmetic-event queue (debris/dust hooks) ---------------

func test_remove_queues_destroy_fx_with_cell() -> void:
	var wv := WorldView.new()
	wv.apply_structure_baseline(Protocol.encode_structure_baseline(Vector2i(0, 0), [
		{"id": 9, "type": 0, "cell": Vector3i(4, 1, 2), "yaw": 3, "chunks": ChunkMask.full_mask(8), "building_id": 0, "owner": 1}]))
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": 9}))
	var fx := wv.take_struct_fx()
	assert_eq(fx.size(), 1, "one destroy fx queued on remove")
	assert_eq(fx[0]["kind"], "destroy", "removal is a destroy event")
	assert_eq(fx[0]["cell"], Vector3i(4, 1, 2), "destroy fx carries the piece cell")
	assert_eq(fx[0]["yaw"], 3, "destroy fx carries the piece yaw")
	assert_eq(wv.take_struct_fx(), [], "queue drained after take")

func test_remove_of_unknown_piece_queues_no_fx() -> void:
	var wv := WorldView.new()
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": 404}))
	assert_eq(wv.take_struct_fx(), [], "removing an absent piece queues nothing")

func test_chunk_damage_queues_damage_fx_only_when_mask_changes() -> void:
	var wv := WorldView.new()
	wv.apply_structure_baseline(Protocol.encode_structure_baseline(Vector2i(0, 0), [
		{"id": 11, "type": 0, "cell": Vector3i(1, 0, 1), "yaw": 0, "chunks": ChunkMask.full_mask(8), "building_id": 0, "owner": 1}]))
	wv.take_struct_fx()   # drain any baseline noise
	var newmask := ChunkMask.full_mask(8) & ~0b1111
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_CHUNK, {"id": 11, "mask": newmask}))
	var fx := wv.take_struct_fx()
	assert_eq(fx.size(), 1, "one damage fx queued on a mask change")
	assert_eq(fx[0]["kind"], "damage", "chunk carve is a damage event")
	assert_eq(fx[0]["cell"], Vector3i(1, 0, 1), "damage fx carries the piece cell")
	# Re-applying the same mask must NOT re-emit (server resends are idempotent cosmetically).
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_CHUNK, {"id": 11, "mask": newmask}))
	assert_eq(wv.take_struct_fx(), [], "no damage fx when the mask is unchanged")

func test_collapse_does_not_queue_per_piece_destroy_fx() -> void:
	# A whole-building collapse plays its own cinematic; it must not also spew a destroy puff per piece.
	var wv := WorldView.new()
	wv._structs[1] = {"id": 1, "type": 2, "cell": Vector3i(0,0,0), "yaw": 0, "chunks": -1, "building_id": 7}
	wv._structs[2] = {"id": 2, "type": 2, "cell": Vector3i(0,1,0), "yaw": 0, "chunks": -1, "building_id": 7}
	wv.apply_collapse(7)
	assert_eq(wv.take_struct_fx(), [], "collapse drop does not queue per-piece destroy fx")

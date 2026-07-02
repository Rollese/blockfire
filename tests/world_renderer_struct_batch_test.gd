extends TestCase
## Incremental structure batching: any structure delta used to free and rebuild EVERY
## MultiMesh batch (~8k pieces regrouped on conquest_town) — a chunk-damage firefight
## produced repeated full-rebuild spikes. Now WorldView tracks dirty piece ids and the
## renderer rebuilds only the affected visual-key groups.

func _rec(id: int, type: int, cell: Vector3i, chunks := -1) -> Dictionary:
	return {"id": id, "type": type, "cell": cell, "yaw": 0, "chunks": chunks,
		"building_id": 0, "owner": 0, "under_construction": 0, "build_progress": 0}

func _wv_with_three_pieces() -> WorldView:
	var wv := WorldView.new()
	wv.apply_structure_baseline(Protocol.encode_structure_baseline(Vector2i.ZERO, [
		_rec(1, 0, Vector3i(0, 0, 0)),
		_rec(2, 0, Vector3i(2, 0, 0)),
		_rec(3, 1, Vector3i(4, 0, 0)),
	]))
	return wv

func test_worldview_tracks_dirty_ids() -> void:
	var wv := _wv_with_three_pieces()
	var d := wv.take_struct_dirty()
	assert_true(bool(d["all"]), "baseline -> everything dirty (full rebuild)")
	assert_false(bool(wv.take_struct_dirty()["all"]), "drained after take")
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_CHUNK,
		{"id": 2, "mask": 12345}))
	d = wv.take_struct_dirty()
	assert_false(bool(d["all"]), "a single delta is not a full rebuild")
	assert_eq((d["ids"] as Array), [2], "exactly the carved piece is dirty")

func test_incremental_update_rebuilds_only_affected_group() -> void:
	var wv := _wv_with_three_pieces()
	var r := WorldRenderer.new()
	r._sync_structure_pool(wv, 0.0)
	assert_true(r._struct_groups.size() >= 2, "type-0 and type-1 groups exist")
	var key3: String = r._struct_key_of[3]
	var other_mmis: Array = (r._struct_groups[key3]["mmis"] as Array).duplicate()
	# Carve piece 2 hard enough to change its damage bucket -> its group must rebuild...
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_CHUNK,
		{"id": 2, "mask": 3}))
	r._sync_structure_pool(wv, 0.1)
	# ...while the untouched type-1 group keeps its exact MultiMesh node instances.
	var after: Array = r._struct_groups[key3]["mmis"]
	assert_eq(after.size(), other_mmis.size(), "untouched group keeps its batch count")
	for i in after.size():
		assert_true(is_same(after[i], other_mmis[i]), "untouched group's MMI %d not recreated" % i)
	r.free()

func test_incremental_remove_drops_piece_from_its_group() -> void:
	var wv := _wv_with_three_pieces()
	var r := WorldRenderer.new()
	r._sync_structure_pool(wv, 0.0)
	var key1: String = r._struct_key_of[1]
	assert_eq((r._struct_groups[key1]["ids"] as Dictionary).size(), 2, "pieces 1+2 share the type-0 group")
	wv.apply_structure_delta(Protocol.encode_structure_delta(Protocol.OP_REMOVE, {"id": 1}))
	r._sync_structure_pool(wv, 0.1)
	assert_eq((r._struct_groups[key1]["ids"] as Dictionary).size(), 1, "removed piece left the group")
	assert_false(r._struct_key_of.has(1), "key index cleaned up")
	r.free()

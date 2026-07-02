extends TestCase
## remotes_at() memoization: the interpolation clock only advances at 30 Hz but client_main +
## the renderer call remotes_at up to 4x per render frame — each call cloned the ENTIRE remote
## set (~23k EntityState allocs/sec at 128p) to produce identical results. Same `now` between
## snapshot applies must return the same cached dict; a new snapshot must invalidate it.

func _snap_bytes(x: float, seq: int) -> PackedByteArray:
	var e := EntityState.new()
	e.pos = Vector3(x, 0, 0)
	return Snapshot.encode(100 + seq, seq, 0, 0, {1: EntityState.new(), 2: e}, {})

func test_same_now_returns_cached_dict() -> void:
	var wv := WorldView.new()
	wv.set_local_id(1)
	wv.apply_snapshot(_snap_bytes(5.0, 1), 1.0)
	var a := wv.remotes_at(1.5)
	var b := wv.remotes_at(1.5)
	assert_true(a == b and a.size() == 1, "identical now within a frame -> one shared sample")
	assert_true(is_same(a[2], b[2]), "cached: same EntityState instance, not a fresh clone")
	var c := wv.remotes_at(1.6)
	assert_false(is_same(a[2], c[2]), "different now -> fresh sample")

func test_snapshot_apply_invalidates_cache() -> void:
	var wv := WorldView.new()
	wv.set_local_id(1)
	wv.apply_snapshot(_snap_bytes(5.0, 1), 1.0)
	var a := wv.remotes_at(9.9)   # far future -> newest buffered state (x=5)
	wv.apply_snapshot(_snap_bytes(8.0, 2), 1.2)
	var b := wv.remotes_at(9.9)   # same clock value, but new data must be visible
	assert_false(is_same(a.get(2), b.get(2)), "apply_snapshot invalidates the memo")
	assert_almost_eq((b[2] as EntityState).pos.x, 8.0, 0.01, "post-apply sample reflects the new snapshot")

extends TestCase
## Transient-FX pool caps (batch 5.3): _puffs/_debris/_blasts/_thrown/_rockets grew unbounded —
## a 128p destruction fight could accumulate thousands of live one-shot nodes. Every pool now
## evicts (frees) its OLDEST entry past a cap; steady-state visuals are unaffected because TTLs
## normally drain pools far below the caps.


func test_puff_pool_capped_and_oldest_evicted() -> void:
	var r = autofree(WorldRenderer.new())
	r._fx.spawn_puff(Vector3.ZERO, 1.0, 99.0, 0.0)
	var first: Node3D = (r._fx.puffs[0] as Dictionary)["node"]
	for _i in preload("res://client/fx_pool.gd").MAX_PUFFS + 9:
		r._fx.spawn_puff(Vector3.ZERO, 1.0, 99.0, 0.0)
	assert_eq(r._fx.puffs.size(), preload("res://client/fx_pool.gd").MAX_PUFFS, "pool holds at the cap")
	assert_false(is_instance_valid(first), "oldest puff was freed, not leaked")


func test_debris_pool_capped() -> void:
	var r = autofree(WorldRenderer.new())
	while r._fx.debris.size() < preload("res://client/fx_pool.gd").MAX_DEBRIS:
		r._fx.spawn_debris(Vector3.ZERO, 0.0)   # spawns a burst per call
	r._fx.spawn_debris(Vector3.ZERO, 0.0)
	assert_eq(r._fx.debris.size(), preload("res://client/fx_pool.gd").MAX_DEBRIS, "debris burst cannot exceed the cap")


func test_blast_pool_capped() -> void:
	var r = autofree(WorldRenderer.new())
	for _i in preload("res://client/fx_pool.gd").MAX_BLASTS + 5:
		r.spawn_explosion(Vector3.ZERO, Protocol.DET_EXPLOSION, 0.0)
	assert_true(r._fx.blasts.size() <= preload("res://client/fx_pool.gd").MAX_BLASTS, "explosion cores capped")
	assert_true(r._fx.debris.size() <= preload("res://client/fx_pool.gd").MAX_DEBRIS, "explosion debris capped")


func test_thrown_and_rocket_pools_capped() -> void:
	var r = autofree(WorldRenderer.new())
	for _i in preload("res://client/fx_pool.gd").MAX_THROWN + 5:
		r.throw_grenade(Vector3.ZERO, Vector3.UP, Grenade.FRAG, 0.0)
	assert_eq(r._fx.thrown.size(), preload("res://client/fx_pool.gd").MAX_THROWN)
	for _i in preload("res://client/fx_pool.gd").MAX_ROCKETS + 5:
		r.fire_rocket(Vector3.ZERO, Vector3.FORWARD, 0.0)
	assert_eq(r._fx.rockets.size(), preload("res://client/fx_pool.gd").MAX_ROCKETS)

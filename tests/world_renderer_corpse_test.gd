extends TestCase
## Corpse-on-death (M7): a dead-in-view pawn drops a lingering body that ages out + is capped.

func _dead_state(tier: int = 0) -> EntityState:
	var es := EntityState.new()
	es.pos = Vector3(3, 0, -5)
	es.yaw = 0.4
	es.alive = false
	es.armor_class = tier
	return es

func test_spawn_corpse_adds_a_body() -> void:
	var r := WorldRenderer.new()
	r._spawn_corpse(_dead_state(Armor.HEAVY), 0.0)
	assert_eq(r._corpses.size(), 1, "a corpse body is laid down")
	r.free()

func test_corpse_ages_out_after_ttl() -> void:
	var r := WorldRenderer.new()
	r._spawn_corpse(_dead_state(), 0.0)
	r._age_corpses(WorldRenderer.CORPSE_TTL + 0.1)
	assert_eq(r._corpses.size(), 0, "corpse despawns past its TTL")
	r.free()

func test_corpse_pool_is_capped() -> void:
	var r := WorldRenderer.new()
	for i in range(WorldRenderer.CORPSE_MAX + 5):
		r._spawn_corpse(_dead_state(), 0.0)
	assert_eq(r._corpses.size(), WorldRenderer.CORPSE_MAX, "oldest corpses recycled at the cap")
	r.free()

func test_non_finite_pos_spawns_nothing() -> void:
	var r := WorldRenderer.new()
	var es := _dead_state()
	es.pos = Vector3(INF, 0, 0)
	r._spawn_corpse(es, 0.0)
	assert_eq(r._corpses.size(), 0, "a non-finite death position is ignored")
	r.free()

extends TestCase
## spawn_impact (M7) drops a small dust puff + a few chips at a bullet's world-impact point, and
## they age out via the existing puff/debris pools.

func test_impact_spawns_a_puff_and_chips() -> void:
	var r := WorldRenderer.new()
	r.spawn_impact(Vector3(2, 1, -3), Protocol.IMPACT_WALL, 0.0)
	assert_true(r._puffs.size() >= 1, "impact spawns a dust puff")
	assert_true(r._debris.size() >= 1, "impact kicks off chips")
	r.free()

func test_flesh_impact_is_a_lighter_mist() -> void:
	var r := WorldRenderer.new()
	r.spawn_impact(Vector3(1, 1, 1), Protocol.IMPACT_FLESH, 0.0)
	assert_true(r._puffs.size() >= 1, "flesh hit spawns a blood mist puff")
	assert_eq(r._debris.size(), 2, "flesh mist has just a couple of droplets (fewer than wall chips)")
	r.free()

func test_impact_non_finite_pos_spawns_nothing() -> void:
	var r := WorldRenderer.new()
	r.spawn_impact(Vector3(INF, 0, 0), Protocol.IMPACT_DIRT, 0.0)
	assert_eq(r._puffs.size(), 0, "no puff at a non-finite point")
	assert_eq(r._debris.size(), 0, "no chips at a non-finite point")
	r.free()

func test_impact_chips_age_out() -> void:
	var r := WorldRenderer.new()
	r.spawn_impact(Vector3.ZERO, Protocol.IMPACT_DIRT, 0.0)
	var n := r._debris.size()
	assert_true(n >= 1)
	r._age_debris(WorldRenderer.DEBRIS_TTL + 0.1, 0.016)   # past the (halved) chip lifetime
	assert_eq(r._debris.size(), 0, "chips are released after their TTL")
	r.free()

extends TestCase
## spawn_explosion (M7) builds the right cosmetic node pools per detonation kind, and they age out.

func test_frag_explosion_spawns_blast_and_debris() -> void:
	var r := WorldRenderer.new()
	r.spawn_explosion(Vector3(0, 0, 0), Protocol.DET_EXPLOSION, 0.0)
	assert_true(r._fx.blasts.size() >= 1, "frag spawns a fireball core")
	assert_true(r._fx.debris.size() >= 1, "frag scatters debris")
	r.free()

func test_flash_explosion_is_a_pop_without_debris() -> void:
	var r := WorldRenderer.new()
	r.spawn_explosion(Vector3.ZERO, Protocol.DET_FLASH, 0.0)
	assert_true(r._fx.blasts.size() >= 1, "flash spawns a white pop")
	assert_eq(r._fx.debris.size(), 0, "flash pop has no debris")
	r.free()

func test_blasts_age_out_after_their_ttl() -> void:
	var r := WorldRenderer.new()
	r.spawn_explosion(Vector3.ZERO, Protocol.DET_EXPLOSION, 0.0)
	assert_true(r._fx.blasts.size() >= 1)
	r._fx.age_blasts(preload("res://client/fx_pool.gd").BLAST_TTL + 0.1)   # past the fireball lifetime
	assert_eq(r._fx.blasts.size(), 0, "fireball cores are released after TTL")
	r.free()

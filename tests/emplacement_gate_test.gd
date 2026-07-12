extends TestCase

func _deployed_manned() -> EmplacementHarness:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	h.move_pawn_to(h.first_nest().seat_world())
	h.mount(h.first_nest_id())
	return h

func test_explosion_destroys_nest_and_ejects_gunner() -> void:
	var h := _deployed_manned()
	var nid := h.first_nest_id()
	assert_true(h.nest(nid).alive)
	h.explode_at(h.nest(nid).pos, 999, 6.0)   # lethal splash at the nest
	assert_false(h.nest(nid).alive, "nest destroyed")
	assert_eq(h.pawn().mounted_nest, 0, "gunner ejected on destruction")
	assert_true(h.pawn().health < 100 or h.pawn().is_downed, "gunner punished by the blast")
	assert_eq(h._stats.nests_destroyed, 1, "telemetry: nest destruction counted")

func test_bullets_chip_nest_hp() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	var hp0 := h.first_nest().hp
	h.bullet_hit_nest(h.first_nest_id(), 30)   # exercises damage() plumbing (the bullet path will call this)
	assert_true(h.first_nest().hp < hp0, "damage chips hp")

func test_partial_splash_is_nonlethal() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))
	var hp0 := h.first_nest().hp
	h.explode_at(Vector3(0, 0, 10), 200, 6.0)   # 5 m away, inside 6 m radius -> falloff, partial
	assert_true(h.first_nest().alive and h.first_nest().hp < hp0 and h.first_nest().hp > 0, "edge blast wounds but doesn't destroy")

func test_friendly_explosion_spares_own_nest() -> void:
	var h := _deployed_manned()   # nest team 1
	var hp0 := h.first_nest().hp
	h.explode_at(h.first_nest().pos, 999, 6.0, 1)   # attacker team == nest team -> FF off
	assert_true(h.first_nest().alive and h.first_nest().hp == hp0, "own team's explosive doesn't damage own nest")

func test_already_dead_gunner_not_punished_twice() -> void:
	var h := _deployed_manned()
	var nid := h.first_nest_id()
	h.pawn().alive = false        # gunner already killed this tick (e.g. by the direct blast)
	var log0 := h.dmg_log.size()
	h.explode_at(h.nest(nid).pos, 999, 6.0)   # destroys the nest
	assert_false(h.nest(nid).alive, "nest destroyed")
	assert_eq(h.dmg_log.size(), log0, "already-dead gunner isn't damaged a second time")
	assert_eq(h.pawn().mounted_nest, 0, "still ejected")

func test_unmanned_nest_destruction_is_safe() -> void:
	var h := EmplacementHarness.new()
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))   # deployed but NOT mounted
	var nid := h.first_nest_id()
	h.explode_at(h.nest(nid).pos, 999, 6.0)
	assert_false(h.nest(nid).alive, "unmanned nest still destructible, no crash on null occupant")

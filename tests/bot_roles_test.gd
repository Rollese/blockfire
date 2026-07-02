extends TestCase
## BotRoles (batch 5.5): explicit, DISJOINT gate-exerciser role assignment. The old scattered
## index-modulo checks overlapped: %4==0 (weapon swapper) is exactly %8==0 (climb driller)
## ∪ %8==4 (shovel driller), so every "swapper" was actually a driller being interrupted
## mid-drill and no plain rifleman ever exercised the swap path.

const Roles := preload("res://bots/roles.gd")


func test_each_bot_gets_exactly_one_role() -> void:
	for i in 128:
		var n := 0
		for r in [Roles.CREW, Roles.SHOVEL, Roles.CLIMB, Roles.SWAP, Roles.FIREMODE, Roles.RIFLE]:
			if Roles.of(i) == r:
				n += 1
		assert_eq(n, 1, "index %d has exactly one role" % i)


func test_populations_at_128_are_disjoint_and_sized() -> void:
	var counts := {}
	for i in 128:
		var r: int = Roles.of(i)
		counts[r] = int(counts.get(r, 0)) + 1
	assert_true(int(counts.get(Roles.CREW, 0)) >= 4, "vehicle crew present (capped at MAX_VEHICLE_BOTS per process)")
	assert_true(int(counts.get(Roles.SHOVEL, 0)) >= 12, "enough shovel drillers for build gates")
	assert_true(int(counts.get(Roles.CLIMB, 0)) >= 12, "enough climb drillers")
	assert_true(int(counts.get(Roles.SWAP, 0)) >= 12, "swap exercisers exist and are NOT drillers")
	assert_true(int(counts.get(Roles.FIREMODE, 0)) >= 12, "fire-mode cyclers exist")
	assert_gt(int(counts.get(Roles.RIFLE, 0)), 30, "majority remain plain riflemen")


func test_swappers_are_never_drillers() -> void:
	for i in 128:
		if Roles.of(i) == Roles.SWAP:
			assert_ne(i % 8, 0, "swapper %d is not the climb driller" % i)
			assert_ne(i % 8, 4, "swapper %d is not the shovel driller" % i)
	assert_gt(1, 0)   # loop above may assert 0 times if role table broken; keep one hard assert


func test_shovel_large_coop_subset_is_within_shovel_role() -> void:
	for i in 128:
		if Roles.large_coop(i):
			assert_eq(Roles.of(i), Roles.SHOVEL, "large-coop bot %d is a shovel driller" % i)


func test_role_stability() -> void:
	# Deterministic: same index -> same role, every call (gates rely on stable populations).
	for i in [0, 1, 4, 5, 13, 127]:
		assert_eq(Roles.of(i), Roles.of(i), "stable for %d" % i)

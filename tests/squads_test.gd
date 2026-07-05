extends TestCase

func test_fills_first_squad_then_overflows() -> void:
	var sm := SquadManager.new()
	for i in SquadManager.SQUAD_SIZE:
		assert_eq(sm.assign(i, 0), 0, "first %d go to squad 0" % SquadManager.SQUAD_SIZE)
	assert_eq(sm.assign(99, 0), 1, "next opens squad 1")

func test_leader_is_first_member_and_promotes() -> void:
	var sm := SquadManager.new()
	sm.assign(10, 0); sm.assign(11, 0)
	assert_eq(sm.leader_of(0, 0), 10)
	sm.remove(10, 0)
	assert_eq(sm.leader_of(0, 0), 11, "next member promoted")

func test_reuses_freed_slot() -> void:
	var sm := SquadManager.new()
	for i in SquadManager.SQUAD_SIZE: sm.assign(i, 0)
	sm.remove(3, 0)
	assert_eq(sm.assign(50, 0), 0, "freed slot in squad 0 reused")

func test_teams_independent() -> void:
	var sm := SquadManager.new()
	assert_eq(sm.assign(1, 0), 0)
	assert_eq(sm.assign(2, 1), 0, "team 1 squad ids independent")

func test_members_lists_squadmates() -> void:
	var sm := SquadManager.new()
	sm.assign(1, 0); sm.assign(2, 0)
	var mem := sm.members(0, 0)
	assert_eq(mem.size(), 2)
	assert_true(1 in mem and 2 in mem)

func test_assign_never_wipes_existing_noncontiguous_squad() -> void:
	# S4 regression (2026-07-04 review): assign() allocated `sid = squads.size()`, but join() creates
	# arbitrary NON-CONTIGUOUS bucket keys — so size() could equal an existing key and `squads[sid]=[]`
	# wiped that squad's member array (members orphaned, leadership hijacked by the new joiner).
	var sm := SquadManager.new()
	var next_id := 100
	for sq in [0, 1, 2, 3]:            # fill squads 0..3 (32 members)
		for i in SquadManager.SQUAD_SIZE:
			assert_true(sm.join(next_id, 0, sq)); next_id += 1
	for i in SquadManager.SQUAD_SIZE:  # fill squad 5 via explicit joins (key 4 never created)
		assert_true(sm.join(next_id, 0, 5)); next_id += 1
	# Buckets are {0,1,2,3,5} -> size()==5 == existing key 5. The old code wiped squad 5 here.
	var sid := sm.assign(999, 0)
	assert_eq(sid, 4, "overflow opens the free id 4, not the existing key 5")
	assert_eq(sm.members(0, 5).size(), SquadManager.SQUAD_SIZE, "squad 5 keeps all its members")
	assert_true(999 in sm.members(0, 4))

extends TestCase

func test_join_moves_member_between_squads_same_team() -> void:
	var sm := SquadManager.new()
	sm.assign(1, 0)
	var b := sm.assign(2, 0)   # client 2's squad
	assert_true(sm.join(1, 0, b), "join target squad succeeds when room")
	assert_eq(sm.squad_of[1], b, "client moved to target squad")
	assert_true(sm.members(0, b).has(1))

func test_join_rejects_when_squad_full() -> void:
	var sm := SquadManager.new()
	# Fill squad 0 to capacity
	for i in SquadManager.SQUAD_SIZE:
		sm.assign(100 + i, 0)
	var target: int = sm.squad_of[100]
	assert_eq(sm.members(0, target).size(), SquadManager.SQUAD_SIZE, "squad at capacity")
	# A new client (assigned to squad 1 since squad 0 is full) cannot join the full squad
	sm.assign(200, 0)
	assert_false(sm.join(200, 0, target), "join rejected when target full")
	assert_eq(sm.members(0, target).size(), SquadManager.SQUAD_SIZE, "full squad unchanged")

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

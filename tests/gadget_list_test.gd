extends TestCase
## GadgetList (M7): flattens the server's live gadget stores (_c4 / _mines / _bags) into one render
## list. Pure, so the client mirrors true server state each broadcast — no per-removal bookkeeping.

func test_empty_stores_give_empty_list() -> void:
	assert_eq(GadgetList.build({}, [], []).size(), 0, "no gadgets -> empty list")

func test_c4_entries_flatten_per_owner() -> void:
	var c4 := {
		7: [{"pos": Vector3(1, 0, 2)}, {"pos": Vector3(3, 0, 4)}],
		9: [{"pos": Vector3(5, 0, 6)}],
	}
	var list := GadgetList.build(c4, [], [])
	assert_eq(list.size(), 3, "all C4 across owners are listed")
	for g in list:
		assert_eq(g["kind"], GadgetList.C4, "C4 entries tagged C4")

func test_mine_keeps_facing() -> void:
	var mines := [{"pos": Vector3(2, 0, 3), "facing": Vector3(1, 0, 0)}]
	var list := GadgetList.build({}, mines, [])
	assert_eq(list.size(), 1)
	assert_eq(list[0]["kind"], GadgetList.MINE, "mine tagged MINE")
	assert_almost_eq(list[0]["face"].x, 1.0, 0.001, "mine facing preserved (drives the cone direction)")

func test_bag_listed_without_facing() -> void:
	var bags := [{"pos": Vector3(8, 0, 9), "kind": Gadget.KIND_AMMO, "team": 1}]
	var list := GadgetList.build({}, [], bags)
	assert_eq(list.size(), 1)
	assert_eq(list[0]["kind"], GadgetList.BAG, "bag tagged BAG")
	# View-only subtype + team flow through so the client can pick the glyph + friendly-ring colour.
	assert_eq(list[0]["subtype"], Gadget.KIND_AMMO, "bag heal/ammo subtype forwarded for the client glyph")
	assert_eq(list[0]["team"], 1, "bag owner team forwarded for the friendly-only ring")

func test_all_three_combine() -> void:
	var list := GadgetList.build({7: [{"pos": Vector3.ZERO}]},
		[{"pos": Vector3(1, 0, 1), "facing": Vector3(0, 0, 1)}],
		[{"pos": Vector3(2, 0, 2), "kind": 1}])
	assert_eq(list.size(), 3, "C4 + mine + bag all present")

func test_cap_bounds_the_list() -> void:
	var mines: Array = []
	for i in range(200):
		mines.append({"pos": Vector3(i, 0, 0), "facing": Vector3(0, 0, 1)})
	var list := GadgetList.build({}, mines, [])
	assert_true(list.size() <= GadgetList.MAX, "list is capped so the packet stays bounded")

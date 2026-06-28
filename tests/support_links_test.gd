extends TestCase
## SupportLinks (M7): flattens the server's per-tick support actions (heal/ammo/repair/revive) into
## one render list broadcast as SUPPORT_LIST, plus the protocol round-trip. Pure + view-only, so the
## client mirrors true server state each broadcast — a giver that stops helping drops out next tick.

func test_empty_events_give_empty_list() -> void:
	assert_eq(SupportLinks.build([]).size(), 0, "no support actions -> empty list")

func test_basic_link_preserved() -> void:
	var list := SupportLinks.build([{"giver": 5, "target": 9, "kind": SupportLinks.HEAL}])
	assert_eq(list.size(), 1)
	assert_eq(list[0]["giver"], 5)
	assert_eq(list[0]["target"], 9)
	assert_eq(list[0]["kind"], SupportLinks.HEAL, "heal tagged HEAL")

func test_drops_self_and_zero_links() -> void:
	var list := SupportLinks.build([
		{"giver": 0, "target": 9, "kind": SupportLinks.HEAL},   # zero giver
		{"giver": 5, "target": 0, "kind": SupportLinks.AMMO},   # zero target
		{"giver": 7, "target": 7, "kind": SupportLinks.REVIVE}, # self-link
	])
	assert_eq(list.size(), 0, "degenerate links are dropped")

func test_dedups_identical_triples() -> void:
	var list := SupportLinks.build([
		{"giver": 5, "target": 9, "kind": SupportLinks.HEAL},
		{"giver": 5, "target": 9, "kind": SupportLinks.HEAL},
	])
	assert_eq(list.size(), 1, "identical (giver,target,kind) collapses to one beam")

func test_same_pair_different_kind_kept() -> void:
	var list := SupportLinks.build([
		{"giver": 5, "target": 9, "kind": SupportLinks.HEAL},
		{"giver": 5, "target": 9, "kind": SupportLinks.AMMO},
	])
	assert_eq(list.size(), 2, "a different support kind is a distinct link")

func test_deterministic_sort() -> void:
	# Unsorted in -> sorted by (giver, target, kind) out, so the server change-detect is stable.
	var list := SupportLinks.build([
		{"giver": 9, "target": 2, "kind": SupportLinks.REPAIR},
		{"giver": 3, "target": 8, "kind": SupportLinks.HEAL},
		{"giver": 3, "target": 1, "kind": SupportLinks.AMMO},
	])
	assert_eq(list[0]["giver"], 3)
	assert_eq(list[0]["target"], 1, "lowest (giver,target) first")
	assert_eq(list[1]["target"], 8)
	assert_eq(list[2]["giver"], 9)

func test_cap_bounds_the_list() -> void:
	var events: Array = []
	for i in range(200):
		events.append({"giver": i + 1, "target": 1000 + i, "kind": SupportLinks.HEAL})
	var list := SupportLinks.build(events)
	assert_true(list.size() <= SupportLinks.MAX, "list is capped so the packet stays bounded")

func test_protocol_round_trip() -> void:
	var src := [
		{"giver": 5, "target": 9, "kind": SupportLinks.HEAL},
		{"giver": 12, "target": 70001, "kind": SupportLinks.REPAIR},
	]
	var bytes := Protocol.encode_support_list(src)
	assert_eq(bytes[0], Protocol.Msg.SUPPORT_LIST, "tagged SUPPORT_LIST")
	var out := Protocol.decode_support_list(bytes)
	assert_eq(out.size(), 2)
	assert_eq(out[0]["giver"], 5)
	assert_eq(out[0]["target"], 9)
	assert_eq(out[0]["kind"], SupportLinks.HEAL)
	assert_eq(out[1]["giver"], 12)
	assert_eq(out[1]["target"], 70001, "vehicle-range target id survives the u32 round-trip")
	assert_eq(out[1]["kind"], SupportLinks.REPAIR)

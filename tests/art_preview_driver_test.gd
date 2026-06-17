extends TestCase

func test_driver_spawns_one_node_per_catalog_entry() -> void:
	var spawned := PreviewDriver.build_catalog()
	# 2 teams of characters + 4 weapons + 1 vehicle*2 teams + 2 structures*4 buckets + 3 props = 19
	# Plan comment said >= 20 but the actual catalog yields 2+4+2+8+3 = 19; assertion corrected.
	assert_true(spawned.size() >= 19, "catalog covers all kit variants, got %d" % spawned.size())
	var kinds := {}
	for item in spawned:
		kinds[item["kind"]] = true
	for k in ["character", "weapon", "vehicle", "structure", "prop"]:
		assert_true(kinds.has(k), "catalog includes a %s" % k)

func test_each_catalog_item_carries_a_node_and_label() -> void:
	for item in PreviewDriver.build_catalog():
		assert_true(item["node"] is Node3D, "item has a Node3D")
		assert_true(String(item["label"]).length() > 0, "item is labeled")

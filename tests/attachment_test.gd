extends TestCase

const VALID := '{"attachments":[' + \
	'{"id":"iron","slot":"optic","spread_mult":1.0},' + \
	'{"id":"reddot","slot":"optic","spread_mult":0.85},' + \
	'{"id":"suppressor","slot":"barrel","range_mult":0.9},' + \
	'{"id":"brake","slot":"barrel","recoil_mult":0.8},' + \
	'{"id":"grip","slot":"underbarrel","move_spread_mult":0.7},' + \
	'{"id":"bipod","slot":"underbarrel","prone_spread_zero":true}]}'

func test_loads_valid() -> void:
	var res := Attachment.from_json_string(VALID)
	assert_true(res["ok"], res["error"])

func test_rejects_unknown_slot() -> void:
	var res := Attachment.from_json_string('{"attachments":[{"id":"x","slot":"scope"}]}')
	assert_false(res["ok"])

func test_rejects_duplicate_id() -> void:
	var res := Attachment.from_json_string('{"attachments":[{"id":"a","slot":"optic"},{"id":"a","slot":"barrel"}]}')
	assert_false(res["ok"])

func test_default_multipliers_are_neutral() -> void:
	var cat: Attachment = Attachment.from_json_string(VALID)["catalog"]
	var m := cat.multipliers({})   # nothing equipped
	assert_almost_eq(m["spread_mult"], 1.0, 0.001)
	assert_almost_eq(m["recoil_mult"], 1.0, 0.001)
	assert_almost_eq(m["range_mult"], 1.0, 0.001)
	assert_almost_eq(m["move_spread_mult"], 1.0, 0.001)
	assert_false(m["prone_spread_zero"])

func test_multipliers_compose_across_slots() -> void:
	var cat: Attachment = Attachment.from_json_string(VALID)["catalog"]
	var m := cat.multipliers({"optic": "reddot", "barrel": "brake", "underbarrel": "bipod"})
	assert_almost_eq(m["spread_mult"], 0.85, 0.001)
	assert_almost_eq(m["recoil_mult"], 0.8, 0.001)
	assert_true(m["prone_spread_zero"])

func test_unknown_id_ignored_as_neutral() -> void:
	var cat: Attachment = Attachment.from_json_string(VALID)["catalog"]
	var m := cat.multipliers({"optic": "nonexistent"})
	assert_almost_eq(m["spread_mult"], 1.0, 0.001)

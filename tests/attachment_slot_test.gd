extends TestCase

func _catalog() -> Attachment:
	var res := Attachment.from_dict({"attachments": [
		{"id": "reddot", "slot": "optic"},
		{"id": "brake", "slot": "barrel"},
	]})
	return res["catalog"]

func test_slot_of_known_id() -> void:
	var c := _catalog()
	assert_eq(c.slot_of("reddot"), "optic")
	assert_eq(c.slot_of("brake"), "barrel")

func test_slot_of_unknown_id_is_empty() -> void:
	assert_eq(_catalog().slot_of("does_not_exist"), "")

func test_has_id() -> void:
	var c := _catalog()
	assert_true(c.has_id("reddot"))
	assert_false(c.has_id("does_not_exist"))

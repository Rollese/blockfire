extends TestCase

const Bot := preload("res://bots/bot_driver.gd")

func test_place_chunk_remove_mirror() -> void:
	var s := {}
	Bot.apply_structure_delta(s, {"op": Protocol.OP_PLACE, "rec": {"id": 5, "chunks": ChunkMask.full_mask(8)}})
	assert_eq(s.has(5), true)
	var newmask := ChunkMask.full_mask(8) & ~0b111
	Bot.apply_structure_delta(s, {"op": Protocol.OP_CHUNK, "id": 5, "mask": newmask})
	assert_eq(s.has(5), true)          # chunk update must NOT erase
	assert_eq(s[5]["chunks"], newmask)
	Bot.apply_structure_delta(s, {"op": Protocol.OP_REMOVE, "id": 5})
	assert_eq(s.has(5), false)

func test_chunk_on_unknown_id_is_noop() -> void:
	var s := {}
	Bot.apply_structure_delta(s, {"op": Protocol.OP_CHUNK, "id": 9, "mask": 0})
	assert_eq(s.has(9), false)

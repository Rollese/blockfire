extends TestCase
const Perception := preload("res://bots/ai/perception.gd")
func test_decays_entries_older_than_lifetime() -> void:
	var mem := {7: {"pos": Vector3(1, 0, 1), "tick": 100}, 8: {"pos": Vector3(2, 0, 2), "tick": 50}}
	var kept := Perception.decay_memory(mem, 145, 90)
	assert_true(kept.has(7), "fresh memory kept")
	assert_false(kept.has(8), "stale memory dropped")
func test_keeps_entry_exactly_at_lifetime_edge() -> void:
	var mem := {9: {"pos": Vector3.ZERO, "tick": 100}}
	var kept := Perception.decay_memory(mem, 190, 90)
	assert_true(kept.has(9), "age == lifetime is not yet expired")

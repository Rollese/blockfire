extends TestCase
const Perception := preload("res://bots/ai/perception.gd")
func test_enemy_not_actionable_before_reaction_delay() -> void:
	assert_false(Perception.is_actionable(100, 108, 9), "8 ticks < 9 delay -> not yet actionable")
func test_enemy_actionable_after_reaction_delay() -> void:
	assert_true(Perception.is_actionable(100, 109, 9), "exactly 9 ticks elapsed -> actionable")
	assert_true(Perception.is_actionable(100, 200, 9), "long-visible enemy stays actionable")

extends TestCase
const AiCover := preload("res://bots/ai/behaviors/cover.gd")
const WorldModel := preload("res://bots/ai/world_model.gd")

func test_picks_nearest_cover_to_self() -> void:
	var w := WorldModel.new()
	w.self_state = EntityState.new()
	w.self_state.pos = Vector3.ZERO
	var c: Array[Vector3] = [Vector3(20,0,0), Vector3(3,0,0), Vector3(50,0,0)]
	w.cover = c
	assert_eq(AiCover.pick_cover(w), Vector3(3,0,0), "nearest cover chosen")

func test_no_cover_returns_self_pos() -> void:
	var w := WorldModel.new()
	w.self_state = EntityState.new()
	w.self_state.pos = Vector3(7,0,7)
	assert_eq(AiCover.pick_cover(w), Vector3(7,0,7), "no cover -> hold position")

func test_desired_stance_crouches_under_fire() -> void:
	assert_eq(AiCover.desired_stance(0.9), Stance.CROUCH, "high pressure -> crouch")
	assert_eq(AiCover.desired_stance(0.0), Stance.STAND, "calm -> stand")

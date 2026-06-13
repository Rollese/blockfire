extends TestCase

func _view(id: int, x: float) -> Dictionary:
	var e := EntityState.new()
	e.pos = Vector3(x, 0, 0)
	return {id: e}

func test_interpolates_between_two_snapshots() -> void:
	var interp := Interpolation.new()
	interp.push(1.0, _view(1, 0.0))
	interp.push(1.1, _view(1, 10.0))   # 10m over 100ms
	# render time = now - DELAY(0.1). now=1.15 -> render at 1.05 = halfway.
	var out := interp.sample(1.15)
	assert_true(out.has(1))
	assert_almost_eq(out[1].pos.x, 5.0, 0.01, "halfway between 0 and 10")

func test_clamps_to_latest_when_render_time_past_newest() -> void:
	var interp := Interpolation.new()
	interp.push(1.0, _view(1, 0.0))
	interp.push(1.1, _view(1, 10.0))
	var out := interp.sample(5.0)  # way past
	assert_almost_eq(out[1].pos.x, 10.0, 0.01)

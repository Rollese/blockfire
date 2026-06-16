extends TestCase

func test_replay_converges_after_authoritative_correction() -> void:
	var pred := Prediction.new()
	# client predicts 3 ticks of +x movement, ticks 1,2,3
	pred.record_input(1, 1.0, 0.0, 0.0)
	pred.record_input(2, 1.0, 0.0, 0.0)
	pred.record_input(3, 1.0, 0.0, 0.0)
	var predicted_x := pred.predicted.pos.x
	# server confirms through tick 1 at the matching authoritative position,
	# but with a small correction (e.g. server placed us 0.5m back).
	var auth := Vector3(Stance.speed(Stance.STAND) * SimLoop.DT - 0.5, 0, 0)
	pred.reconcile(auth, 0.0, 1)
	# inputs 2 and 3 remain and are replayed from the authoritative base.
	assert_eq(pred.pending.size(), 2, "ticks 2,3 still pending")
	var expected := auth.x + 2.0 * Stance.speed(Stance.STAND) * SimLoop.DT
	assert_almost_eq(pred.predicted.pos.x, expected, 0.0001)
	assert_true(absf(pred.predicted.pos.x - predicted_x) > 0.0, "correction applied")

func test_full_ack_clears_pending() -> void:
	var pred := Prediction.new()
	pred.record_input(1, 1.0, 0.0, 0.0)
	pred.reconcile(Vector3(1, 0, 0), 0.0, 1)
	assert_eq(pred.pending.size(), 0)
	assert_almost_eq(pred.predicted.pos.x, 1.0, 0.0001, "no replay, sits at authoritative")

func test_record_cmd_steps_with_buttons_and_pitch() -> void:
	var pred := Prediction.new()
	pred.record_cmd(1, {"move_x": 0.0, "move_y": 1.0, "yaw": 0.5, "pitch": -0.2,
		"buttons": InputCommand.BTN_CROUCH})
	assert_eq(pred.predicted.stance, Stance.CROUCH, "crouch button applied via shared Pawn.step")
	assert_almost_eq(pred.predicted.pitch, -0.2, 0.001)

func test_reconcile_full_sets_pitch_and_replays() -> void:
	var pred := Prediction.new()
	pred.record_cmd(1, {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.0, "buttons": 0})
	pred.record_cmd(2, {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.3, "buttons": 0})
	pred.reconcile_full(Vector3(0.1, 0, 0), 0.0, 0.0, 1)
	assert_eq(pred.pending.size(), 1, "tick 2 replayed")
	assert_almost_eq(pred.predicted.pitch, 0.3, 0.001, "pitch from replayed cmd")

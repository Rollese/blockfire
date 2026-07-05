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

func test_reconcile_restores_stamina_so_sprint_replay_doesnt_double_drain() -> void:
	# Regression (M7 playtest): reconcile reset pos/yaw/pitch but NOT stamina, while replaying every
	# pending input re-drained stamina each snapshot (~RTT x too fast). The predicted sprint then hit
	# empty stamina and dropped to walk speed while the server kept sprinting -> forward rubber-band in
	# the open. Reconciling stamina to authority makes replay drain from the correct baseline.
	var pred := Prediction.new()
	pred.world_half = 1000.0
	var sprint := {"move_x": 0.0, "move_y": 1.0, "yaw": 0.0, "pitch": 0.0, "buttons": InputCommand.BTN_SPRINT}
	for t in range(1, 11):
		pred.record_cmd(t, sprint)   # client predicts 10 sprint ticks ahead of the server
	# Server acked through tick 7 with its authoritative stamina (7 sprint-steps drained).
	var auth_stamina: float = Pawn.STAMINA_MAX - Pawn.SPRINT_DRAIN * SimLoop.DT * 7.0
	pred.reconcile_full(Vector3.ZERO, 0.0, 0.0, 7, auth_stamina)
	assert_eq(pred.pending.size(), 3, "ticks 8,9,10 replayed")
	# Replays 3 sprint steps from the AUTHORITATIVE stamina, not the drifted predicted value.
	var expected: float = auth_stamina - Pawn.SPRINT_DRAIN * SimLoop.DT * 3.0
	assert_almost_eq(pred.predicted.stamina, expected, 0.5,
		"stamina reconciles to authority + replay drain, not accumulated double-drain")

func test_reconcile_restores_vertical_velocity_so_jump_arc_doesnt_snap() -> void:
	# Regression (M7 playtest B3): reconcile reset pos but NOT velocity.y/grounded. Replaying pending
	# inputs after a mid-jump snapshot integrated gravity from a stale vertical velocity, so the predicted
	# jump arc diverged from authority and got yanked back ("pulled to my previous position when jumping").
	var pred := Prediction.new()
	pred.world_half = 1000.0
	var air := {"move_x": 0.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.0, "buttons": 0}
	for t in range(1, 11):
		pred.record_cmd(t, air)   # 10 predicted airborne ticks
	# Authority acked tick 7 mid-jump: rising at +3.0 m/s, airborne, 2.0 m up.
	var auth_vy := 3.0
	pred.reconcile_full(Vector3(0.0, 2.0, 0.0), 0.0, 0.0, 7, Pawn.STAMINA_MAX, auth_vy, false)
	assert_eq(pred.pending.size(), 3, "ticks 8,9,10 replayed")
	# 3 airborne replay steps apply gravity from the AUTHORITATIVE vertical velocity, not a drifted one.
	var expected_vy: float = auth_vy - Pawn.GRAVITY * SimLoop.DT * 3.0
	assert_almost_eq(pred.predicted.velocity.y, expected_vy, 0.01,
		"vertical velocity reconciles to authority + replay gravity")

func test_reconcile_resyncs_vault_progress_instead_of_stale_arc() -> void:
	# Global-review C1 (same bug class as stamina/velocity.y): reconcile never touched the vault
	# fields. While vaulting, SimLoop drives pos FROM the stored arc — so the stale local arc
	# overrode the authoritative position and every replayed input advanced vault_tick again on top
	# of the per-tick advance: the predicted 8-tick vault finished (1+pending)x too fast, stuttering
	# every auto-vault. Authority now replicates (vaulting, vault_tick); reconcile re-syncs progress.
	var pred := Prediction.new()
	pred.world_half = 1000.0
	var fwd := {"move_x": 0.0, "move_y": 1.0, "yaw": 0.0, "pitch": 0.0, "buttons": 0}
	# Predicted pawn is mid-vault, further along than the server (arc from z=0 to z=2.5).
	Vault.begin_at(pred.predicted, Vector3.ZERO, Vector3(0, 0, 2.5))
	pred.predicted.vault_tick = 6
	for t in range(1, 4):
		pred.pending.append({"tick": t, "cmd": fwd})   # 3 unacked inputs to replay
	# Authority acked tick 0 with the vault only 2 ticks in.
	pred.reconcile_full(Vault.arc_pos(Vector3.ZERO, Vector3(0, 0, 2.5), 2.0 / 8.0), 0.0, 0.0, 0,
		Pawn.STAMINA_MAX, 0.0, true, true, 2)
	# 2 (authority) + 3 replayed ticks = 5: same progress the server will have at our current tick.
	assert_true(pred.predicted.vaulting, "still mid-vault after reconcile")
	assert_eq(pred.predicted.vault_tick, 5, "vault progress = authority + replay, not stale local arc")
	var expect := Vault.arc_pos(Vector3.ZERO, Vector3(0, 0, 2.5), 5.0 / 8.0)
	assert_almost_eq(pred.predicted.pos.z, expect.z, 0.01, "position follows the re-synced arc")

func test_reconcile_cancels_vault_the_server_never_ran() -> void:
	# If authority says NOT vaulting, a predicted arc must not keep overriding the authoritative
	# position (it teleports the camera along a vault the server refused).
	var pred := Prediction.new()
	pred.world_half = 1000.0
	Vault.begin_at(pred.predicted, Vector3.ZERO, Vector3(0, 0, 2.5))
	pred.predicted.vault_tick = 3
	pred.reconcile_full(Vector3(0, 0, 0.4), 0.0, 0.0, 5, Pawn.STAMINA_MAX, 0.0, true, false, 0)
	assert_false(pred.predicted.vaulting, "refused/finished server vault cancels the local arc")
	assert_almost_eq(pred.predicted.pos.z, 0.4, 0.001, "authoritative position wins")

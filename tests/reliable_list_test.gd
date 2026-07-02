extends TestCase
## ReliableList: the changed+heartbeat send-decision shared by GADGET/SUPPORT/DOWNED/FOB_LIST
## (previously four hand-rolled copies of {last_pkt, hb_tick} in server_main).

const RL := preload("res://server/reliable_list.gd")


func _pkt(b: int) -> PackedByteArray:
	return PackedByteArray([b, 1, 2])


func test_first_packet_always_sends() -> void:
	var rl := RL.new()
	assert_true(rl.should_send(_pkt(1), false, 0), "initial state differs from any packet — sends even when empty")


func test_unchanged_packet_does_not_resend() -> void:
	var rl := RL.new()
	rl.should_send(_pkt(1), true, 10)
	assert_false(rl.should_send(_pkt(1), true, 11), "same bytes next tick -> silent")


func test_changed_packet_sends() -> void:
	var rl := RL.new()
	rl.should_send(_pkt(1), true, 10)
	assert_true(rl.should_send(_pkt(2), true, 11))


func test_heartbeat_resends_nonempty_list_after_interval() -> void:
	var rl := RL.new()
	rl.should_send(_pkt(1), true, 10)
	assert_false(rl.should_send(_pkt(1), true, 10 + RL.HEARTBEAT_TICKS - 1), "just under the interval")
	assert_true(rl.should_send(_pkt(1), true, 10 + RL.HEARTBEAT_TICKS), "~1 Hz heartbeat for late joiners")
	assert_false(rl.should_send(_pkt(1), true, 10 + RL.HEARTBEAT_TICKS + 1), "heartbeat clock re-latched on send")


func test_no_heartbeat_when_list_empty() -> void:
	var rl := RL.new()
	rl.should_send(_pkt(1), false, 10)
	assert_false(rl.should_send(_pkt(1), false, 10 + RL.HEARTBEAT_TICKS * 3),
		"an empty list never heartbeats — nothing for a late joiner to miss")


func test_per_team_dictionary_payloads_compare_by_content() -> void:
	# FOB_LIST keeps one packet per team ({0: pkt, 1: pkt}); deep equality drives `changed`.
	var rl := RL.new()
	assert_true(rl.should_send({0: _pkt(1), 1: _pkt(2)}, true, 0))
	assert_false(rl.should_send({0: _pkt(1), 1: _pkt(2)}, true, 1), "equal-content dict -> unchanged")
	assert_true(rl.should_send({0: _pkt(1), 1: _pkt(3)}, true, 2), "one team's list changed -> send")

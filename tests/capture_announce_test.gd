extends TestCase
## CaptureAnnounce (M7): detects capture-point ownership changes between match-state broadcasts and
## classifies each relative to the local team, so the HUD can banner "POINT B CAPTURED / LOST". Pure.

func test_no_change_no_events() -> void:
	assert_eq(CaptureAnnounce.diff([0, 1, -1], [0, 1, -1], 0).size(), 0, "unchanged owners -> no banners")

func test_we_capture_a_point_is_friendly() -> void:
	var ev := CaptureAnnounce.diff([-1], [0], 0)   # neutral -> our team
	assert_eq(ev.size(), 1)
	assert_eq(ev[0]["index"], 0)
	assert_eq(ev[0]["status"], CaptureAnnounce.FRIENDLY, "we took it -> friendly")

func test_enemy_takes_our_point_is_hostile() -> void:
	var ev := CaptureAnnounce.diff([0], [1], 0)   # ours -> enemy
	assert_eq(ev[0]["status"], CaptureAnnounce.HOSTILE, "enemy captured -> hostile")

func test_point_going_neutral_is_neutral() -> void:
	var ev := CaptureAnnounce.diff([0], [-1], 0)   # ours -> neutral (contested away)
	assert_eq(ev[0]["status"], CaptureAnnounce.NEUTRAL, "neutralized -> neutral")

func test_enemy_capturing_a_neutral_is_hostile() -> void:
	var ev := CaptureAnnounce.diff([-1], [1], 0)
	assert_eq(ev[0]["status"], CaptureAnnounce.HOSTILE, "enemy took a neutral -> hostile")

func test_unknown_team_classifies_by_owner() -> void:
	# my_team -1 (not yet known): a team-0 capture is not "ours", so hostile; neutral stays neutral.
	assert_eq(CaptureAnnounce.diff([-1], [0], -1)[0]["status"], CaptureAnnounce.HOSTILE)
	assert_eq(CaptureAnnounce.diff([0], [-1], -1)[0]["status"], CaptureAnnounce.NEUTRAL)

func test_multiple_changes_reported() -> void:
	var ev := CaptureAnnounce.diff([-1, 0, 1], [0, 0, -1], 0)   # A: we cap, B: same, C: neutralized
	assert_eq(ev.size(), 2, "only the changed points")
	assert_eq(ev[0]["index"], 0)
	assert_eq(ev[1]["index"], 2)

func test_size_mismatch_is_safe() -> void:
	assert_eq(CaptureAnnounce.diff([0, 1], [0], 0).size(), 0, "compares only the overlapping points")

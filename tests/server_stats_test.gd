extends TestCase
## ServerStats: the ~57-counter telemetry wall extracted from server_main (batch 5.2).
## The [telemetry] line format is gate-scraper-critical (docker/_gate_lib.sh anchored greps),
## so it is pinned here byte-for-byte.

const Stats := preload("res://server/stats.gd")


func test_window_reset_zeroes_window_counters_not_cumulative() -> void:
	var s := Stats.new()
	s.kills = 3
	s.transport_max = 9.5
	s.cap_events = 2
	s.cap_events_total = 5
	s.fobs_destroyed = 1
	s.dbg_last_min_y = 1.25
	s.reset_window()
	assert_eq(s.kills, 0, "window counter zeroed")
	assert_eq(s.transport_max, 0.0, "float window counter zeroed")
	assert_eq(s.cap_events, 0, "window cap_events zeroed")
	assert_eq(s.fobs_destroyed, 0)
	assert_eq(s.dbg_last_min_y, INF, "projectile test seam re-arms to INF")
	assert_eq(s.cap_events_total, 5, "cumulative match total survives the window reset")


func test_telemetry_line_format_pinned() -> void:
	# Golden line: every gate scraper greps anchored `(^| )name=` fields out of this string —
	# if a rename/reorder breaks a scraper, this test breaks first.
	var s := Stats.new()
	s.kills = 4
	s.shots = 204
	s.hits = 51
	s.fobs_destroyed = 1
	var line := s.telemetry_line(128, 100, 16.48, 22.10, 15.6, 0.25, 2, 80, 55, "0.1", 76)
	assert_true(line.begins_with("[telemetry] players=128 alive=100 tick_mean=16.48ms tick_p99=22.10ms agg=15.6Mbit/s pktloss=0.25%"),
		"header fields pinned")
	assert_contains(line, " kills=4 shots=204 hit_rate=0.25 starv=2 ", "combat block pinned (hit_rate = hits/shots)")
	assert_contains(line, " t0=80 t1=55 pts=0.1 ", "ticket/points block pinned")
	assert_contains(line, " struct=76 ", "structure count from caller pinned")
	assert_contains(line, " fobs_destroyed=1 ", "FOB block pinned")
	assert_contains(line, "nests_dep=0 nests_man=0 nests_dead=0 ", "nest telemetry block present (M19 P4)")
	assert_contains(line, " shield_blk=0 shield_brk=0 ", "riot-shield telemetry block present (M19 P5)")
	assert_contains(line, " grapples_dep=0 grapple_climbs=0 grapple_cuts=0 ", "grapple telemetry block present (M19 grapple)")
	assert_true(line.ends_with("mags_dropped=0 mags_picked=0 redist=0"), "line ends with the M2 ammo telemetry block")
	assert_contains(line, " destroyed=0 ", "destroyed= present (anchored scrapers depend on the leading space)")


func test_hit_rate_zero_shots_is_zero() -> void:
	var s := Stats.new()
	var line := s.telemetry_line(0, 0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0, "", 0)
	assert_contains(line, " hit_rate=0.00 ", "no divide-by-zero on an idle window")

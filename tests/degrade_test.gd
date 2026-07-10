extends TestCase
## M8-P3 adaptive snapshot-degradation ladder. Pure hysteresis logic (docs/specs/m8-hardening-ops.md).

func test_baseline_level_holds_in_band() -> void:
	# Level 0 is the undegraded baseline; in the hysteresis band it must not move.
	assert_eq(Degrade.next_level(20.0, 0), 0, "under budget stays at baseline")
	assert_eq(Degrade.next_level(28.0, 0), 0, "in-band (26..30) holds at baseline")

func test_climbs_over_high_water() -> void:
	assert_eq(Degrade.next_level(31.0, 0), 1, "over HIGH_MS climbs one step")
	assert_eq(Degrade.next_level(31.0, 1), 2, "keeps climbing while over budget")

func test_clamps_at_max_level() -> void:
	var top := Degrade.max_level()
	assert_eq(Degrade.next_level(40.0, top), top, "cannot climb past the top of the ladder")

func test_descends_below_low_water() -> void:
	assert_eq(Degrade.next_level(20.0, 2), 1, "recovered below LOW_MS descends one step")
	assert_eq(Degrade.next_level(20.0, 1), 0, "descends back to baseline")
	assert_eq(Degrade.next_level(20.0, 0), 0, "cannot descend below baseline")

func test_hysteresis_band_holds_current_level() -> void:
	# Between LOW_MS(26) and HIGH_MS(30) the level neither climbs nor descends (no flip-flop).
	assert_eq(Degrade.next_level(28.0, 1), 1, "in-band holds a degraded level (no thrash)")

func test_injectable_thresholds() -> void:
	# Thresholds are parameters (server exposes CLI overrides) — a low high-water forces a climb.
	assert_eq(Degrade.next_level(10.0, 0, 5.0, 3.0), 1, "custom high-water triggers a climb")

func test_ladder_params_shed_load_monotonically() -> void:
	# Level 0 must equal the server's static baseline (1, 24 — full 30 Hz since ADR-0003 A.5).
	# The first degrade step is the historical stride-2 (15 Hz) baseline; higher levels keep
	# shedding: longer send stride (lower rate) and fewer distant enemies replicated.
	assert_eq(Degrade.stride_for(0), 1)
	assert_eq(Degrade.enemy_cap_for(0), 24)
	assert_eq(Degrade.stride_for(1), 2, "first degrade step = the old 15 Hz baseline")
	for lv in range(1, Degrade.max_level() + 1):
		assert_true(Degrade.stride_for(lv) > Degrade.stride_for(lv - 1) \
			or Degrade.enemy_cap_for(lv) < Degrade.enemy_cap_for(lv - 1), "every step sheds load")
		assert_true(Degrade.stride_for(lv) >= Degrade.stride_for(lv - 1))
		assert_true(Degrade.enemy_cap_for(lv) <= Degrade.enemy_cap_for(lv - 1))

func test_inverted_degrade_band_from_cli_reverts_to_defaults() -> void:
	# --degrade-high-ms/--degrade-low-ms were unvalidated: an inverted band (low >= high)
	# makes Degrade.next_level climb one window and descend the next, thrashing the
	# snapshot stride every second. Operator error must fall back to the safe defaults.
	var srv = preload("res://server/server_main.gd").new()
	srv.configure({"degrade-high-ms": 10.0, "degrade-low-ms": 20.0})
	assert_almost_eq(srv._degrade_high_ms, Degrade.HIGH_MS, 0.001, "inverted band: high reverts to default")
	assert_almost_eq(srv._degrade_low_ms, Degrade.LOW_MS, 0.001, "inverted band: low reverts to default")
	srv.free()
	var ok = preload("res://server/server_main.gd").new()
	ok.configure({"degrade-high-ms": 28.0, "degrade-low-ms": 22.0})
	assert_almost_eq(ok._degrade_high_ms, 28.0, 0.001, "valid band accepted (high)")
	assert_almost_eq(ok._degrade_low_ms, 22.0, 0.001, "valid band accepted (low)")
	ok.free()

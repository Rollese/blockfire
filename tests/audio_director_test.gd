extends TestCase

func _dir() -> AudioDirector:
	var d := AudioDirector.new()
	var cat := AudioCatalog.new()
	cat.load_from("res://data/sounds.json")
	d.setup(cat, 32)
	return d

func test_resolve_culls_out_of_range() -> void:
	var d := _dir()
	# gunfire max_distance 400 -> at 500 it must cull
	var out := d.resolve("gunfire", 500.0, 0.0, 0.0)
	assert_true(out["culled"], "beyond max_distance is culled before the voice pool")

func test_resolve_audible_in_range() -> void:
	var d := _dir()
	var out := d.resolve("gunfire", 16.0, 0.0, 0.0)
	assert_false(out["culled"], "in-range is audible")
	assert_true(out["gain"] > 0.0, "positive gain")
	assert_eq(out["bus"], "SFX", "routes to its def bus")
	assert_eq(int(out["priority"]), 2, "carries the def priority for the pool")

func test_resolve_occlusion_darkens_and_quiets() -> void:
	var d := _dir()
	var clear := d.resolve("gunfire", 16.0, 0.0, 0.0)
	var blocked := d.resolve("gunfire", 16.0, 1.0, 0.0)
	assert_true(blocked["gain"] < clear["gain"], "occluded is quieter")
	assert_true(blocked["cutoff"] < clear["cutoff"], "occluded is darker")

func test_resolve_suppressed_def_smaller_signature() -> void:
	var d := _dir()
	# at 200 m: normal gunfire (max 400) audible, suppressed (max 120) culled
	assert_false(d.resolve("gunfire", 200.0, 0.0, 0.0)["culled"], "normal carries to 200 m")
	assert_true(d.resolve("gunfire_supp", 200.0, 0.0, 0.0)["culled"], "suppressed dies before 200 m")

func test_play_event_drops_when_pool_full() -> void:
	var d := AudioDirector.new()
	var cat := AudioCatalog.new()
	cat.load_from("res://data/sounds.json")
	d.setup(cat, 1)
	# one CRITICAL holds the single slot; a LOW footstep nearby must be dropped (no bind).
	var a := d.decide("explosion", 5.0, 0.0, 0.0)
	var b := d.decide("footstep", 5.0, 0.0, 0.0)
	assert_true(a["slot"] >= 0, "explosion gets the only slot")
	assert_eq(b["slot"], -1, "footstep dropped when pool full and outranked")

func test_engine_loop_stream_is_seamless_and_loops() -> void:
	# The engine voice must loop without the one-shot decay (which would click each wrap).
	var s := AudioDirector._gen_engine_loop()
	assert_eq(s.loop_mode, AudioStreamWAV.LOOP_FORWARD, "engine stream loops forward")
	assert_true(s.data.size() > 0, "engine buffer is non-empty")
	assert_eq(s.loop_end, s.data.size() / 2, "loop spans the whole 16-bit buffer (seamless wrap)")

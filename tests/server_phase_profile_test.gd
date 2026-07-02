extends TestCase
## Phase-profiler bucket contract: the old `respawn` bucket silently covered TWELVE
## subsystems (grenades..vehicle respawns), so the [perf] line — the triage tool when the
## degrade ladder trips — could not say which system was hot. It must be split into
## ordnance / support / build / respawn.

func test_phase_buckets_split_the_old_respawn_catchall() -> void:
	var srv = preload("res://server/server_main.gd").new()
	for k in ["poll", "move", "veh", "lag", "interest", "fire",
			"ordnance", "support", "build", "respawn", "conquest", "match", "snap"]:
		assert_true(srv._phase_us.has(k), "[perf] bucket '%s' exists" % k)
	srv.free()

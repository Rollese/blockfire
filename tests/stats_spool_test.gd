extends TestCase

const Spool := preload("res://server/stats/stats_spool.gd")

const PATH := "user://test_stats_spool.ndjson"

func teardown() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))

func test_append_and_read_all_roundtrips() -> void:
	var s: Spool = Spool.new(PATH)
	s.clear()
	s.append({"path": "/ingest/match", "body": {"match_id": "m1"}})
	s.append({"path": "/ingest/events", "body": {"batch_seq": 0}})
	var rows := s.read_all()
	assert_eq(rows.size(), 2, "two spooled rows")
	assert_eq(rows[0]["path"], "/ingest/match", "first row path")
	assert_eq(rows[1]["body"]["batch_seq"], 0, "second row body")

func test_clear_empties_the_spool() -> void:
	var s: Spool = Spool.new(PATH)
	s.append({"path": "/x", "body": {}})
	s.clear()
	assert_eq(s.read_all().size(), 0, "cleared")

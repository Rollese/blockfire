class_name StatsSpool
extends RefCounted

# Append-only NDJSON fallback: when a POST fails, its {path, body} is spooled
# here and re-sent on the next successful drain. One JSON object per line.

var _path: String

func _init(path: String = "user://stats_spool.ndjson") -> void:
	_path = path

func append(record: Dictionary) -> void:
	var f := FileAccess.open(_path, FileAccess.READ_WRITE) if FileAccess.file_exists(_path) \
		else FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_error("StatsSpool: cannot open %s" % _path)
		return
	f.seek_end()
	f.store_line(JSON.stringify(record))
	f.close()

func read_all() -> Array:
	var out: Array = []
	if not FileAccess.file_exists(_path):
		return out
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges().is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if parsed != null:
			out.append(parsed)
	f.close()
	return out

func clear() -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f != null:
		f.close()

func is_empty() -> bool:
	return read_all().is_empty()

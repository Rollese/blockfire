extends Node
## Headless test runner. Loads tests/**/*_test.gd, runs each test_* method, prints
## PASS/FAIL, and quits with code 0 (all pass) or 1 (any fail).
## Run: godot --headless --path . -- --test [--filter=substr]

func _ready() -> void:
	var filter := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.substr("--filter=".length())

	var total := 0
	var failed := 0
	for path in _discover("res://tests"):
		var script: GDScript = load(path)
		var inst = script.new()
		for m in inst.get_method_list():
			var name: String = m.name
			if not name.begins_with("test_"):
				continue
			if filter != "" and not (name.contains(filter) or path.get_file().contains(filter)):
				continue
			total += 1
			inst.reset()
			inst.call(name)
			if inst.failures.is_empty():
				print("  PASS %s::%s" % [path.get_file(), name])
			else:
				failed += 1
				for f in inst.failures:
					print("  FAIL %s::%s — %s" % [path.get_file(), name, f])
	print("TESTS: %d run, %d failed" % [total, failed])
	get_tree().quit(1 if failed > 0 else 0)

func _discover(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			out.append_array(_discover(full))
		elif name.ends_with("_test.gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out

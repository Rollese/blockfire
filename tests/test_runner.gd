extends Node
## Headless test runner. Loads tests/**/*_test.gd, runs each test_* method via
## TestCase.run_one (setup/teardown/autofree lifecycle + runtime-error detection via a
## registered TestErrorTally), prints PASS/FAIL with per-test timing, and quits with
## code 0 (all pass) or 1 (any fail). A test file that fails to parse counts as one
## failure — previously it aborted _ready before quit() and the process hung forever.
## Run: godot --headless --path . -- --test [--filter=substr]

const ErrorTally := preload("res://tests/error_tally.gd")   # preload: class_name needs an --import to register

func _ready() -> void:
	var filter := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.substr("--filter=".length())

	var tally := ErrorTally.new()
	OS.add_logger(tally)
	var suite_t0 := Time.get_ticks_usec()
	var total := 0
	var failed := 0
	for path in _discover("res://tests"):
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			if filter == "" or path.get_file().contains(filter):
				total += 1
				failed += 1
				print("  FAIL %s — file failed to parse (see SCRIPT ERROR above)" % path.get_file())
			continue
		var inst = script.new()
		if inst is not TestCase:
			continue
		for m in inst.get_method_list():
			var name: String = m.name
			if not name.begins_with("test_"):
				continue
			if filter != "" and not (name.contains(filter) or path.get_file().contains(filter)):
				continue
			total += 1
			var res: Dictionary = TestCase.run_one(inst, name, tally)
			if res["failed"]:
				failed += 1
				for r in res["reasons"]:
					print("  FAIL %s::%s — %s" % [path.get_file(), name, r])
			else:
				print("  PASS %s::%s (%.1f ms)" % [path.get_file(), name, res["ms"]])
	OS.remove_logger(tally)
	print("TESTS: %d run, %d failed (%.1f s)" % [total, failed, float(Time.get_ticks_usec() - suite_t0) / 1e6])
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

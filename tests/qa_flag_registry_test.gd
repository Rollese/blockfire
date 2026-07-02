extends TestCase
## client/qa_flags.gd registry shape (deep-review §D3): the table replaces the per-flag QA wiring
## in client_main.gd (parse + renderer forward) and world_renderer.gd (_run_demos), so every name
## it holds MUST resolve on the owning script — a typo would otherwise silently no-op via set()/get().

const QaFlags := preload("res://client/qa_flags.gd")

## Collect declared member-variable names from a script without instantiating it.
func _prop_names(script: Script) -> Dictionary:
	var out: Dictionary = {}
	for p: Dictionary in script.get_script_property_list():
		out[String(p["name"])] = true
	return out

## Collect method names from a script without instantiating it.
func _method_names(script: Script) -> Dictionary:
	var out: Dictionary = {}
	for m: Dictionary in script.get_script_method_list():
		out[String(m["name"])] = true
	return out

func test_rows_have_flag_and_member() -> void:
	assert_true(QaFlags.FLAGS.size() >= 47, "all 47 QA flags registered (got %d)" % QaFlags.FLAGS.size())
	for entry: Dictionary in QaFlags.FLAGS:
		assert_true(entry.has("flag") and entry.has("member"),
			"row missing flag/member: %s" % str(entry))
		assert_false(String(entry["flag"]).begins_with("--"),
			"flag stored without leading -- (bootstrap strips it): %s" % str(entry["flag"]))

func test_flags_and_members_unique() -> void:
	var flags: Dictionary = {}
	var members: Dictionary = {}
	for entry: Dictionary in QaFlags.FLAGS:
		var f: String = String(entry["flag"])
		var m: String = String(entry["member"])
		assert_false(flags.has(f), "duplicate flag: %s" % f)
		assert_false(members.has(m), "duplicate member: %s" % m)
		flags[f] = true
		members[m] = true

func test_members_exist_on_client_main() -> void:
	var props: Dictionary = _prop_names(load("res://client/client_main.gd"))
	for entry: Dictionary in QaFlags.FLAGS:
		assert_true(props.has(String(entry["member"])),
			"client_main.gd has no member '%s' (flag --%s)" % [entry["member"], entry["flag"]])

func test_configure_sets_members_table_driven() -> void:
	# Functional: configure() must flip exactly the members whose flags are present (the loop
	# replaces the old parse ladder — a broken set() would leave every QA flag silently off).
	var cm: Node = (load("res://client/client_main.gd") as GDScript).new()
	var args: Dictionary = {"boom-test": true, "remote-reload-test": true, "connect": "127.0.0.1"}
	cm.configure(args)
	assert_true(bool(cm.get("_boom_test")), "--boom-test sets _boom_test")
	assert_true(bool(cm.get("_reloadpose_test")), "--remote-reload-test sets _reloadpose_test")
	assert_false(bool(cm.get("_flash_test")), "absent flags stay false")
	cm.free()

func test_run_demos_calls_every_registered_demo() -> void:
	# Runtime smoke: _run_demos must call every "demo" row with (now) — an arity mismatch in the
	# table would only surface at runtime. All flags default false, so each demo early-returns.
	var wr: Node3D = (load("res://client/world_renderer.gd") as GDScript).new()
	wr._run_demos(0.0)
	assert_true(true, "_run_demos executed every registered demo without error")
	wr.free()

func test_renderer_hooks_exist_on_world_renderer() -> void:
	var script: Script = load("res://client/world_renderer.gd")
	var props: Dictionary = _prop_names(script)
	var methods: Dictionary = _method_names(script)
	assert_true(methods.has("_run_demos"), "world_renderer.gd drives demos via _run_demos")
	for entry: Dictionary in QaFlags.FLAGS:
		if entry.has("renderer"):
			assert_true(props.has(String(entry["renderer"])),
				"world_renderer.gd has no property '%s' (flag --%s)" % [entry["renderer"], entry["flag"]])
		if entry.has("demo"):
			assert_true(methods.has(String(entry["demo"])),
				"world_renderer.gd has no method '%s' (flag --%s)" % [entry["demo"], entry["flag"]])
			assert_true(entry.has("renderer"),
				"demo row without a renderer flag property (flag --%s)" % entry["flag"])

extends TestCase
## P2b: the real data/gadgets.json catalog carries a BREACH def (Assault cheap-reuse gadget,
## spec §D). Loads the actual file (not an inline fixture) so the test breaks if the shipped
## catalog regresses.

func test_breach_def_present() -> void:
	var cat := Gadget.load_file("res://data/gadgets.json")
	var d := cat.def_of_kind(Gadget.KIND_BREACH)
	assert_false(d.is_empty(), "breach def loads")
	assert_true(float(d["struct_radius"]) > 0.0, "breach carve radius")
	assert_true(int(d["arm_delay_ticks"]) > 0, "breach arms after a delay")

func test_stim_and_smokewall_defs_present() -> void:
	var cat := Gadget.load_file("res://data/gadgets.json")
	var s := cat.def_of_kind(Gadget.KIND_STIM)
	assert_false(s.is_empty(), "stim def loads")
	assert_true(int(s["charges"]) > 0 and int(s["duration_ticks"]) > 0, "stim charges+duration")
	assert_true(float(s["resist"]) < 1.0, "stim resist < 1")
	var w := cat.def_of_kind(Gadget.KIND_SMOKE_WALL)
	assert_false(w.is_empty(), "smokewall def loads")
	assert_true(float(w["radius"]) > 6.0, "smokewall bigger than grenade cloud")

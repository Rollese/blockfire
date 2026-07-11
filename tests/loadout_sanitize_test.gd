extends TestCase
## P2b: BREACH (Assault) and REPAIR (Engineer) cheap-reuse gadgets are now selectable and must
## survive sanitize like any other implemented gadget (spec §D). Sim/wire/client land in later
## P2b tasks; this file only proves the registration + validation plumbing.

func setup() -> void:
	Weapon.reset_registry()
	var res := Weapon.load_from_file("res://data/weapons.json")
	assert_true(res["ok"], "weapons.json loads: %s" % res.get("error", ""))

func teardown() -> void:
	Weapon.reset_registry()

func _attach() -> Attachment:
	var res := Attachment.from_dict({"attachments": [
		{"id": "iron", "slot": "optic"},
		{"id": "reddot", "slot": "optic"},
		{"id": "standard", "slot": "barrel"},
		{"id": "none_ub", "slot": "underbarrel"},
	]})
	return res["catalog"]

func test_breach_and_repair_are_implemented() -> void:
	assert_true(Loadout.GADGET_BREACH in Loadout.IMPLEMENTED_GADGETS, "BREACH selectable")
	assert_true(Loadout.GADGET_REPAIR in Loadout.IMPLEMENTED_GADGETS, "REPAIR selectable")

func test_assault_breach_survives_sanitize() -> void:
	var cfg := Loadout.default_loadout(Loadout.ASSAULT)
	cfg["gadget"] = Loadout.GADGET_BREACH
	assert_eq(int(Loadout.sanitize(cfg, _attach())["gadget"]), Loadout.GADGET_BREACH, "Assault keeps BREACH")

func test_engineer_repair_survives_sanitize() -> void:
	var cfg := Loadout.default_loadout(Loadout.ENGINEER)
	cfg["gadget"] = Loadout.GADGET_REPAIR
	assert_eq(int(Loadout.sanitize(cfg, _attach())["gadget"]), Loadout.GADGET_REPAIR, "Engineer keeps REPAIR")

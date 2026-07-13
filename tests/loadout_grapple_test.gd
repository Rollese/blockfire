extends TestCase
## GRAPPLE is now a real, selectable Assault gadget; sanitize keeps it; a bot Assault can roll it.

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

func test_grapple_is_implemented() -> void:
	assert_true(Loadout.GADGET_GRAPPLE in Loadout.IMPLEMENTED_GADGETS, "GRAPPLE selectable")

func test_sanitize_keeps_grapple_for_assault() -> void:
	var lo := Loadout.default_loadout(Loadout.ASSAULT)
	lo["gadget"] = Loadout.GADGET_GRAPPLE
	var clean := Loadout.sanitize(lo, _attach())
	assert_eq(int(clean["gadget"]), Loadout.GADGET_GRAPPLE, "assault keeps grapple")

func test_some_assault_bot_rolls_grapple() -> void:
	var found := false
	for id in range(0, 60):
		if Loadout.bot_gadget(id, Loadout.ASSAULT) == Loadout.GADGET_GRAPPLE:
			found = true; break
	assert_true(found, "at least one assault bot id maps to GRAPPLE")

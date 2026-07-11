extends TestCase

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

func test_rpg_gadget_now_implemented() -> void:
	assert_contains(Loadout.IMPLEMENTED_GADGETS, Loadout.GADGET_RPG)

func test_bot_loadout_is_sanitize_stable() -> void:
	var attach := _attach()
	for id in range(0, 64):
		var lo := Loadout.bot_loadout(id, attach)
		assert_eq(Loadout.sanitize(lo, attach), lo, "bot_loadout(%d) stable under sanitize" % id)

func test_bot_loadout_covers_matrix() -> void:
	var attach := _attach()
	var classes := {}
	var armors := {}
	var has_rpg_engineer := false
	var has_lmg_support := false
	for id in range(0, 64):
		var lo := Loadout.bot_loadout(id, attach)
		classes[int(lo["class"])] = true
		armors[int(lo["armor"])] = true
		if int(lo["class"]) == Loadout.ENGINEER and int(lo["gadget"]) == Loadout.GADGET_RPG:
			has_rpg_engineer = true
		if int(lo["class"]) == Loadout.SUPPORT and Weapon.archetype_of(int(lo["primary"])) == Weapon.LMG:
			has_lmg_support = true
	assert_eq(classes.size(), 4, "all four classes appear")
	assert_eq(armors.size(), 3, "all three armor tiers appear")
	assert_true(has_rpg_engineer, "at least one Engineer runs the RPG gadget")
	assert_true(has_lmg_support, "at least one Support runs an LMG primary")

func test_bot_loadout_every_gadget_implemented() -> void:
	var attach := _attach()
	for id in range(0, 64):
		assert_contains(Loadout.IMPLEMENTED_GADGETS, int(Loadout.bot_loadout(id, attach)["gadget"]))
